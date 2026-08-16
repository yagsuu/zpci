# Architecture

Status: Approved.

This specification owns zpci layering, dependency direction, I/O seams, shared
representation boundaries, and cross-domain ownership. Domain specifications
own behavior within their layer. This document does not define domain API
signatures or operation sequences.

## Layers

```text
caller
  -> ECAM segments, root resource windows, interrupt-routing inputs
  -> ConfigSpace and BarMemory accessors

config/       configuration-space access and function validation
core/         identifier values and package errors
header/       common, type-0, and type-1 configuration headers
bar/          BAR decode and sizing probe
capabilities/ capability traversal and PCIe capability decode
memory/       BAR-mapped memory access
resources/    resource model, assignment, bridge windows, and programming
interrupts/   INTx pin decode and MSI/MSI-X programming
topology/     enumeration, tree construction, and bridge traversal
testing/      byte-backed host-test accessors

pci.zig and namespace facades
  -> public re-exports only
```

The caller constructs accessors and supplies platform policy. zpci reads and
programs PCI state only through its explicit accessors.

## Layer ownership

| Layer | Responsibility |
| --- | --- |
| `core/` | Identifier newtypes, BDF/SBDF arithmetic, and package errors. It has no header, capability, topology, or resource semantics. |
| `config/` | `ConfigSpace`, `Ecam`, `Pio`, and `Function`. It is the only layer that performs configuration MMIO or PIO. |
| `header/` | Header wire layouts, typed header operations, and header-register programming helpers. |
| `bar/` | BAR decode and the save/probe/restore sizing operation. |
| `capabilities/` | Standard and extended capability traversal and PCIe capability decode. It does not dispatch device behavior. |
| `memory/` | `BarMemory`, the semantic-free accessor for BAR-mapped memory. |
| `resources/` | Resource requirements, pure assignment, bridge-window encoding, bus programming, and assignment commit. |
| `interrupts/` | INTx pin decode and MSI/MSI-X capability and table programming. |
| `topology/` | Read-only enumeration, borrowed tree construction, and bridge traversal. |
| `testing/` | Byte-backed test accessors. Production layers do not import it. |

## Global ownership rules

1. `config/` owns configuration-space I/O. Other layers receive `ConfigSpace`
   or `Function` values and do not perform config MMIO or PIO directly.
2. `memory/` owns BAR-memory I/O. MSI-X table and pending-bit-array operations
   use `BarMemory`, not `ConfigSpace`.
3. `header/` owns PCI header wire layouts, packed register values, layout
   assertions, and typed header operations.
4. `bar/` owns BAR sizing writes. Resource programming owns final BAR base
   writes.
5. `resources/` separates pure assignment from programming. Assignment does
   not perform I/O; programming is the explicit commit boundary.
6. `topology/` does not program BARs, bridge windows, bus numbers, command
   registers, MSI, or MSI-X during enumeration or traversal.
7. `interrupts/` consumes caller-supplied routing inputs. zpci does not allocate
   vectors or access APIC, IOAPIC, interrupt-remapping, firmware, or OS routing
   facilities.
8. Capability traversal and decode do not use registries, device dispatchers,
   or generic capability handlers. Callers select behavior explicitly.
9. `pci.zig` and `src/<domain>.zig` facade files contain re-exports only.

## Dependency direction

```text
pci.zig
  -> namespace facades
    -> domain implementations
      -> core/ and approved zstdx primitives
```

The following dependencies are permitted:

- `core/` and `memory/` import only `std`, `builtin`, and approved `zstdx` namespaces.
- `config/` imports `core/` and `zstdx`.
- `header/`, `bar/`, and `capabilities/` import `core/` and `config/`.
  Header modules may import the pure `interrupts/pin.zig` decoder.
- `resources/` imports `core/`, `config/`, `header/`, and `bar/`.
- `interrupts/pin.zig` imports only `std`. Other interrupt modules import
  `core/`, `config/`, `header/`, `capabilities/`, and `memory/`.
- `topology/` imports `core/`, `config/`, and `header/`.
- `testing/` may import production layers. Production layers must not import `testing/`.

An implementation module must not introduce an unlisted lower-to-higher import
or an import cycle. Move a shared semantic-free primitive to `core/`; leave a
cross-domain policy decision to the caller.

## Representation boundaries

zpci keeps wire types and semantic types separate.

- Wire types describe PCI configuration or BAR-memory layout. They use the
  required layout representation and colocated assertions.
- Semantic types describe decoded values, iterators, assignments, and routing
  inputs. They do not expose raw wire pointers across domain boundaries.
- Reads decode wire values into semantic values. Writes encode semantic values
  inside the owning domain.

`ConfigSpace` is the sole public function-pointer/vtable seam. Views hold
explicit access values and identifiers; they do not hold independent function
pointers.

## I/O and lifetime

`ConfigSpace` accesses one PCIe function configuration window. `BarMemory`
accesses caller-mapped BAR memory. These accessors are distinct and remain
valid only while their caller-provided backing resources remain valid.

Views and iterators borrow their accessors and observe live device state. A
topology tree borrows its `ConfigSpace`. An assignment plan is a semantic record
that does not borrow hardware; it remains meaningful only while the caller
maintains the hardware assumptions used to produce it.

## Platform boundaries

zpci supports little-endian hosts. PCI configuration space and BAR memory are
little-endian. `ConfigSpace` and `BarMemory` return native integer values under
that host assumption.

`Pio` consumes `stdx.arch.x86_64.Port`. zpci has no `src/arch/` layer and does
not own port allocation or inline assembly. Platform-specific behavior outside
configuration-access adapters is outside this specification.

zpci does not own ACPI parsing, platform resource discovery, BAR-memory mapping,
driver binding, device reset, VFIO policy, SR-IOV lifecycle, or PCIe services
that lack an approved domain specification.

## Verification boundary

The default host suite uses byte-backed `ConfigSpace` and `BarMemory` accessors
through the production contracts. Decode, sizing, traversal, assignment,
programming, and interrupt behavior must remain host-testable through those
accessors. `docs/guidelines/testing.md` owns the detailed test policy.
