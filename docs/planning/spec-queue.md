# Spec queue

This document is planning material. Normative requirements live only under `docs/specs/` after user approval.

## Workflow

1. Pick the next item from `Queue`.
2. Present a concise decision proposal to the user before writing:
   - decision points and recommended answers;
   - owned scope and non-goals;
   - public namespace/type shape;
   - semantic contracts (validation, presence, dispatch, ordering);
   - wire/layout invariants where the spec owns a wire type;
   - view/iterator/builder behavior;
   - example usage;
   - open questions.
3. Wait for explicit approval.
4. Write the approved spec under `docs/specs/`.
5. Move the item from `Queue` to `Approved`.
6. Repeat.

Implementation work begins only after the required specs for that slice are approved and written.

## Proposal requirements

Proposals are decision packs, not full prose specs. Each proposal must be concise enough to review in one pass and concrete enough to approve.

Every proposal must include:

- decisions requested from the user;
- recommended answer for each decision;
- owned scope;
- deferred scope and non-goals;
- namespace and public type shape;
- operation semantics where signatures are not yet approved;
- allocation, waiting, capacity, invalidation, concurrency, and ordering contracts where relevant;
- wire/layout invariants where the spec owns an `extern struct` or packed word;
- required tests at category level;
- constructor naming: pure assembly is `init` (returns `Self`); fallible input-validation is `from` (returns `Error!Self`); fallible with I/O is `validate` (returns `Error!Self`); presence-bypass is `unchecked`; scratch-backed collection is `intoScratch(buf, ...)` returning a borrowed view (upfront `StorageExhausted` check);
- open questions.

Proposals must not include:

- implementation work;
- full final-spec prose;
- speculative future phases;
- rejected alternatives unless the user asks for comparison;
- hidden defaults that decide policy for downstream consumers.

## Approved

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/bdf.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/config/ecam.md`
- `docs/specs/config/pio.md`
- `docs/specs/header/common.md`
- `docs/specs/header/type0.md`
- `docs/specs/header/type1.md`
- `docs/specs/bar.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/capabilities/extended.md`
- `docs/specs/capabilities/pcie.md`
- `docs/specs/memory/bar.md`
- `docs/specs/resources/model.md`
- `docs/specs/topology/tree.md`
- `docs/specs/topology/enumerate.md`
- `docs/specs/topology/bridge.md`
- `docs/specs/resources/bridge.md`
- `docs/specs/resources/assignment.md`
- `docs/specs/resources/programming.md`
- `docs/specs/resources/bus.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`

## Queue

Prioritized for implementation value across the PCI/PCIe surface. A proposal stays near the top only when it adds a distinct zpci contract beyond Zig language features or `std`/`zstdx` functionality.

### Examples

- `docs/specs/examples/enumerate-ecam.md`
- `docs/specs/examples/size-bars.md`
- `docs/specs/examples/assign-resources.md`
- `docs/specs/examples/program-msi.md`
- `docs/specs/examples/walk-capabilities.md`
- `docs/specs/examples/bridge-traversal.md`

## Deferred pending distinct zpci contract

- SR-IOV, ARI, ATS, AER, ACS, PRI, PASID, DOE, and other extended-capability semantics beyond list traversal and explicitly specced programming surfaces. Promote individually when a concrete zpci consumer needs the capability's programming surface, not the traversal alone.
- Device-driver binding, protocol publication, or firmware integration policy.
- VFIO passthrough policy or config-shadowing.
- PCI device reset policy.
- MSI/MSI-X interrupt remapping policy.
- Non-x86_64 architecture-specific behavior in the initial library.
