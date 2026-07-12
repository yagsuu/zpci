# Spec writing

This guide defines how zpci specs under `docs/specs/` are written and
reviewed. Approved specs are normative for public API, behavior, ownership, and
implementation tests.

## Authority

- Approved specs under `docs/specs/` define contracts.
- Planning documents under `docs/planning/` guide queued work but are not
  authoritative for landed code.
- Source module headers cite the owning spec path.
- A public module without an approved owning spec does not land.

## Status values

Each spec starts with exactly one status line after the title:

```text
Status: Draft.
Status: Approved.
Status: Superseded by <path>.
```

`Draft` specs are review material. Implementation work lands only from
`Approved` specs.

## Language

Spec language is normative. Use direct contract statements and RFC 2119 terms
when a requirement is mandatory. Avoid narration, rationale, history, meeting
context, approval context, and references that require knowledge outside the
repository. A reader must be able to implement and test the spec from the spec
text and linked repository paths alone.

Do not include ephemeral phrases such as \"as discussed\", \"for now\", \"future
work\", \"until a consumer appears\", or \"the approved proposal\". Keep decision
history outside approved specs.

## Standard section order

New and substantially revised specs under `docs/specs/` use this section order
unless a section is irrelevant to the primitive being specified:

1. `# <Spec title>`
2. `Status: Draft.`, `Status: Approved.`, or `Status: Superseded by <path>.`
3. short description;
4. `## What this spec is`;
5. `## What this spec is not`;
6. `## Terminology`, when the spec uses terms that need fixed meanings;
7. `## Public namespace and source ownership`;
8. `## Cross-spec relationships`;
9. `## Data structures and representation`;
10. `## Global invariants`;
11. `## API`;
12. per-operation sections for non-trivial public functions;
13. `## Implementation constraints`;
14. `## Testing`;
15. `## Usage examples`, when examples clarify composition.

Existing approved specs do not need format-only rewrites. Apply this format when
creating a new spec or making a substantial behavioral revision.

## Section rules

### Short description

The short description is one paragraph. It states what the public primitive is
and the concrete job it performs. It is not rationale, marketing, or a tutorial.

### What this spec is

This section owns scope. List the public namespace, types, operations, storage,
state transitions, ordering, invalidation, and required tests that the spec
controls.

### What this spec is not

This section lists non-goals and deferred siblings. It must exclude adjacent
policy domains explicitly enough that implementations do not absorb them by
accident.

### Terminology

Include this section when terms are easy to misuse or have domain-specific
meaning. Definitions are normative when later API sections rely on them.

### Public namespace and source ownership

This section states:

- public import paths;
- root promotions, when the spec adds declarations to `src/pci.zig`;
- facade exports;
- implementation source files;
- required test files.

Omit root-promotion discussion when the public paths listed by the spec are the
entire public surface. State explicit non-promotion only when it prevents a
likely ambiguity, such as a name collision with an existing root export.

Domain facades stay thin. They may import, re-export, and alias approved public
surfaces; they must not contain implementation logic.

### Cross-spec relationships

List required dependencies and intentional composition points. Distinguish
"depends on" from "composes with but does not own".

### Data structures and representation

Distinguish conceptual representation from required implementation
representation.

If layout, ABI, wire format, packing, padding, or field names are guaranteed,
say exactly what is guaranteed. If they are not guaranteed, say so.

### Global invariants

List invariants that every operation preserves. Prefer testable statements:
fixed capacity, monotonic counters, exclusive ownership, no allocation, no
waiting, pointer stability, state-machine restrictions, and no-mutation-on-error
rules.

### API

Show the approved public surface in Zig snippets. Public signatures in this
section are normative. Keep private helper names out unless their shape is part
of the public contract.

Per-operation sections are required for public functions that mutate state,
perform atomics, can fail, can wait, can allocate, affect lifetime, invalidate
handles or pointers, or define concurrency/order semantics.

Use these subsections where applicable and omit irrelevant ones:

- `Contract` for preconditions, postconditions, and caller responsibilities;
- `Invariants` for operation-local invariants not covered globally;
- `State transitions` for before/after state changes;
- `Errors and fault behavior` for returned errors, no-mutation-on-error,
  caller-contract violations, assertions, traps, and release-mode behavior;
- `Locking and waiting` for locks, backend calls, spinning, yielding, parking,
  or an explicit `never`;
- `Allocation behavior` for allocation, freeing, borrowing, or an explicit
  `never`;
- `NMI/interrupt safety` for execution-context safety and the reason;
- `Memory ordering` for atomic orderings and happens-before edges;
- `Concurrency effects` for legal concurrent callers and external
  serialization requirements;
- `Invalidation and lifetime` for handles, pointers, borrowed storage, copying,
  moving, and deinitialization effects;
- `Complexity/progress` for operation cost, boundedness, lock-freedom,
  wait-freedom, blocking, and retry behavior.

Trivial accessors may be grouped when their contracts are identical.

### Implementation constraints

Use this section for normative implementation requirements that are not obvious
from signatures: one-CAS publication, cache-line padding, no hidden globals, no
callbacks, no allocator, no scheduler calls, exact field names, or required
algorithm shape.

### Testing

The testing section states required tests. Split tests by purpose where
applicable:

- required positive tests;
- required negative tests;
- edge cases;
- error and fault behavior;
- concurrency, model, and stress tests;
- memory-ordering tests;
- layout and representation tests.

Tests should enforce invariants and contracts, not mirror implementation
mechanics unless representation is itself normative.

### Usage examples

Usage examples are optional and illustrative unless they explicitly state a
normative requirement. Keep examples short and focused on composition boundaries.
Do not put long tutorials in specs.

## Template

```md
# <Spec title>

Status: Draft.

<One-paragraph short description.>

## What this spec is

<Owned scope.>

## What this spec is not

<Non-goals and deferred siblings.>

## Terminology

<Optional fixed terms.>

## Public namespace and source ownership

<Public paths, root promotion, facade exports, source files, test files.>

## Cross-spec relationships

<Required dependencies and intentional composition points.>

## Data structures and representation

<Conceptual model. Required representation/layout if any. Invalid states. ABI
or layout guarantees, or explicit non-guarantees.>

## Global invariants

<System-wide invariants every operation preserves.>

## API

<Approved public surface.>

### `<function/type/member>`

#### Contract

<Preconditions, postconditions, caller responsibilities.>

#### Invariants

<Function-specific invariants. Omit if fully covered globally.>

#### State transitions

<Before/after state. Omit for pure accessors.>

#### Errors and fault behavior

<Returned errors, no-mutation-on-error, caller-contract violations, traps.>

#### Locking and waiting

<Locks taken, backend calls, spin/park/yield behavior, or `never`.>

#### Allocation behavior

<Allocates/frees/borrows/calls allocator, or `never`.>

#### NMI/interrupt safety

<Safe/unsafe and why.>

#### Memory ordering

<Atomic orderings and happens-before edges.>

#### Concurrency effects

<Who may call concurrently, what races are legal, who owns serialization.>

#### Invalidation and lifetime

<Handles, pointers, borrowed storage, copying/moving, deinit effects.>

#### Complexity/progress

<O(1), O(n), bounded/unbounded retry, lock-free/wait-free/blocking.>

## Implementation constraints

<Normative implementation constraints.>

## Testing

### Required positive tests

### Required negative tests

### Edge cases

### Error and fault behavior

### Concurrency, model, and stress tests

### Memory-ordering tests

### Layout and representation tests

## Usage examples

<Optional illustrative examples.>
```
