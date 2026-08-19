# zpci package index

Status: Approved.

`zpci` is a Zig 0.16 library for explicit PCI and PCI Express
configuration-space access, topology discovery, resource planning, and
interrupt programming. Downstream code imports the public package module as
`pci`.

This specification owns package scope, the public namespace catalog, and the
package-level boundaries below. Domain specifications own representation, API
signatures, and operation behavior. A domain specification prevails if it
conflicts with this document.

## Package boundary

`zpci` operates through caller-provided platform facts and explicit accessors.

It owns these PCI mechanisms:

- PCI identifiers and BDF/SBDF values.
- Configuration-space access through `ConfigSpace`, ECAM, and x86_64 PIO.
- Function validation, header views, BAR decode and sizing, and capability traversal.
- Topology enumeration and bridge traversal.
- Resource modeling, assignment planning, bridge-window encoding, and explicit programming commits.
- MSI and MSI-X capability and table programming.
- Byte-backed configuration-space and BAR-memory accessors for host tests.

## Package product

`build.zig` exposes the `pci` module.
`zig build test` runs the host-side suite without hardware, a VM, or external tools.

The package depends on Zig `std` and `zstdx`. It does not import downstream
consumers or platform-description libraries.

## Public namespaces

`src/pci.zig` re-exports these namespaces. The package facade and namespace
facades re-export declarations only; they do not perform allocation, I/O,
validation, enumeration, dispatch, assignment, or programming.

| Namespace | Responsibility | Owning specification |
| --- | --- | --- |
| `pci.core` | PCI identifiers, BDF/SBDF values, and package errors | `core/*.md` |
| `pci.config` | Configuration-space accessor, function view, ECAM, and PIO | `config/*.md` |
| `pci.header` | Common, endpoint, and bridge header layouts and operations | `header/*.md` |
| `pci.bar` | BAR decode and sizing | `bar.md` |
| `pci.capabilities` | Standard, extended, and PCIe capability traversal and decode | `capabilities/*.md` |
| `pci.memory` | BAR-mapped memory accessor | `memory/bar.md` |
| `pci.resources` | Resource model, assignment, bridge windows, bus programming, and commit | `resources/*.md` |
| `pci.interrupts` | INTx pin decode and MSI/MSI-X programming | `interrupts/*.md` |
| `pci.topology` | Enumeration, topology tree, and bridge traversal | `topology/*.md` |
| `pci.testing` | Host-test configuration-space and BAR-memory accessors | `config/accessor.md`, `memory/bar.md` |

## Cross-domain rules

- Public configuration-space I/O goes through `pci.config.ConfigSpace`.
- MSI-X table and pending-bit-array I/O goes through `pci.memory.BarMemory`.
- Enumeration is read-only. BAR sizing is the only read-scope operation that writes configuration space; it restores the pre-probe state.
- Resource assignment produces a plan without configuration-space I/O. Programming commits that plan explicitly.
- MSI and MSI-X consume caller-provided routing inputs. zpci does not allocate platform vectors.
- Public validation reports typed errors for malformed hardware bytes and inputs. Assertions identify caller-contract violations after validation establishes the applicable invariant.
- Domain specifications define exact allocation, lifetime, ordering, failure, and concurrency behavior.

## Specification catalog

| Area | Specifications |
| --- | --- |
| Architecture | [`architecture.md`](architecture.md) |
| Core | [`core/errors.md`](core/errors.md), [`core/ids.md`](core/ids.md), [`core/bdf.md`](core/bdf.md) |
| Configuration | [`config/accessor.md`](config/accessor.md), [`config/space.md`](config/space.md), [`config/ecam.md`](config/ecam.md), [`config/pio.md`](config/pio.md) |
| Headers | [`header/common.md`](header/common.md), [`header/type0.md`](header/type0.md), [`header/type1.md`](header/type1.md) |
| BARs | [`bar.md`](bar.md) |
| Capabilities | [`capabilities/list.md`](capabilities/list.md), [`capabilities/extended.md`](capabilities/extended.md), [`capabilities/pcie.md`](capabilities/pcie.md) |
| BAR memory | [`memory/bar.md`](memory/bar.md) |
| Resources | [`resources/model.md`](resources/model.md), [`resources/assignment.md`](resources/assignment.md), [`resources/bridge.md`](resources/bridge.md), [`resources/bus.md`](resources/bus.md), [`resources/programming.md`](resources/programming.md) |
| Interrupts | [`interrupts/pin.md`](interrupts/pin.md), [`interrupts/msi.md`](interrupts/msi.md), [`interrupts/msix.md`](interrupts/msix.md) |
| Topology | [`topology/enumerate.md`](topology/enumerate.md), [`topology/tree.md`](topology/tree.md), [`topology/bridge.md`](topology/bridge.md) |

## Related documents

- [`architecture.md`](architecture.md) defines layering, dependency direction, I/O seams, and cross-domain ownership.
- [`../guidelines/conventions.md`](../guidelines/conventions.md) defines source and specification conventions.
- [`../guidelines/testing.md`](../guidelines/testing.md) defines the host-test contract.
- [`../planning/spec-queue.md`](../planning/spec-queue.md) records unapproved planning work.
