# Spec queue

Items become normative only after approval and publication in `docs/specs/`.

## Workflow

1. Select an item from `Queue`.
2. Present a proposal.
3. Get approval.
4. Write the approved spec under `docs/specs/` and move the item to `Approved`.
5. Start implementation after the slice's required specs are approved.

## Proposal contents

Include:

- decisions and recommendations;
- owned and deferred scope;
- public API shape and behavior;
- applicable allocation, capacity, invalidation, concurrency, ordering, and
  wire-layout constraints;
- test categories;
- open questions.

Use the constructor vocabulary in
[`docs/guidelines/conventions.md`](../guidelines/conventions.md#constructors).

Do not include implementation, final-spec prose, speculative phases, rejected
alternatives unless comparison is requested, or unstated downstream policy.

## Queue

## Approved

## Deferred

- SR-IOV, ARI, ATS, AER, ACS, PRI, PASID, DOE, and other extended-capability semantics beyond list traversal and explicitly specced programming surfaces. Promote individually when a concrete zpci consumer needs the capability's programming surface, not the traversal alone.
- Device-driver binding, protocol publication, or firmware integration policy.
- VFIO passthrough policy or config-shadowing.
- PCI device reset policy.
- MSI/MSI-X interrupt remapping policy.
- Non-x86_64 architecture-specific behavior in the initial library.
