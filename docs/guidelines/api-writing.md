# API documentation

`docs/api/` records caller-visible API contracts. Organize pages by responsibility,
not source file. One page can cover several types or modules.

Review test: **Can this be shorter without losing readability or information a
caller needs?**

- Delete facts already clear from names, types, or linked contracts.
- Combine repeated conditions and qualifications.
- Prefer tables for policies, bounds, and failure outcomes; retain prose for
  sequencing and exceptions that tables would obscure.
- Describe guarantees, not execution steps. Keep essential preconditions and
  partial-failure behavior explicit.
- Use no word-count target or mandatory presentation format.

## Content

- State what callers supply, what an operation changes, and what callers can rely on.
- Explain units, inclusive/exclusive bounds, sentinels, and unknown values only where
  declarations do not make them clear.
- Distinguish validated inputs from caller requirements. A mechanical register
  update does not imply feature or platform-policy validation.
- For fallible writes, describe the resulting hardware state: unchanged, restored,
  partially programmed, or cleanup incomplete. Do not imply atomicity.
- State ordering when it affects correctness. Omit private helpers, storage choices,
  algorithms, and exact I/O counts unless they are contractual.
- Include allocation, lifetime, invalidation, timing, and concurrency constraints
  only where they affect use. Do not add blanket sections or lists of absent effects.
- Define shared rules once and link to them. Do not repeat error unions, register
  layouts, signatures, namespace inventories, or export snippets.
- Link to owning source declarations. Include a signature or example only when it
  resolves an ambiguity that prose does not.
- Cite PCI specification revisions and clauses for hardware requirements. External
  references are permitted; the local contract must still state its usable behavior.
- Keep test cases and fixture mechanics in tests, not API docs.

## Language

- Use direct statements and short operation groups.
- Use `MUST` or `MUST NOT` for essential obligations or prohibitions when useful;
  ordinary descriptions need no requirement keyword.
- Give a condition, actor, and observable result when ambiguity is possible.
- Distinguish absent, empty, zero, invalid, and uninspected values.
- Omit narration, approval history, rationale unrelated to use, speculative features,
  `Value:` labels, origin tags, and empty sections.

## Template

Headings below are prompts, not required sections. Omit or combine them when useful.

```markdown
# `pci.<namespace>`

<One sentence defining the owned responsibility.>

## Values

<Units, bounds, sentinels, unknown encodings, and other non-obvious meanings.>

## Operations

### `<operation or related operation group>`

- <Caller requirements.>
- <Result and observable effects.>
- <Preservation and ordering guarantees that affect correctness.>
- <Failure conditions and resulting state.>

## References

<Owning source links and relevant PCI specification clauses.>
```

## Maintenance

- Published pages describe settled contracts. Proposals and unresolved decisions
  stay outside `docs/api/`; published pages need no approval-status header.
- Resolve code/documentation conflicts explicitly. Neither stale prose nor existing
  implementation automatically defines intended behavior.
- Update a contract when observable behavior changes, not when private code moves.
- Replace obsolete pages and update their links; do not retain forwarding pages or
  a parallel legacy tree.
- No one-page-per-module rule, mandatory source-header citation, or prescribed
  implementation sequence applies.
- Review each statement against source and relevant tests. Remove statements that
  add no information beyond declarations or another contract.
