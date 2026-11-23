# Conventions

Implementation conventions for zpci source and API docs. Terse rules; deviations need a reason in review.

These conventions extend `docs/guidelines/zig.md` and `docs/guidelines/api-writing.md`.

## API contracts

`docs/api/` records caller-visible behavior by responsibility. Follow
`docs/guidelines/api-writing.md` for scope, format, and maintenance.

- Keep API contracts distinct from source-style rules and planning notes.
- Resolve conflicting contracts before changing behavior; do not silently choose
  stale prose or implementation as authority.
- No API page is required per source file or public module.
- Planning notes do not define production API contracts.

## Module structure

Domain ownership and I/O boundaries are defined in [the API index](../api/index.md).
Keep source structure aligned with those owners, not source-file length.

- `src/pci.zig` exports named namespaces only.
- Directory namespaces use `module.zig`; a cohesive single-file namespace needs no
  forwarding directory. Namespace entry points may own their types and operations.
- Do not add a forwarding-only `model.zig` beside `module.zig`, or generic
  `utils.zig`, `helpers.zig`, `common.zig`, or `misc.zig` files.
- Split substantive type families or mechanics with distinct responsibilities.
  Put operations on their natural owner; do not wrap `std`/`stdx` without a domain need.
- Wire cross-namespace named imports in `build/modules.zig`; import same-namespace
  siblings directly. Do not retain public aliases at superseded paths.

Canonical byte records use `stdx.layout.Struct` when explicit offsets clarify the
layout. Packed registers use their canonical packed/BitField representation.
Bundles of separate registers and semantic ranges are not contiguous wire images.
Use generated header gaps rather than declaring reserved fields; preserve padding
when modifying an existing image.

## Imports and aliases

Use the baseline import and alias rules in `docs/guidelines/zig.md`.

zpci additions:

- Top-of-file groups, separated by one blank line: `std`/`builtin`; external packages; local module imports; module aliases; utility/offset type aliases; PCI-owned type aliases; value constants; function aliases.
- Import names mirror the module's own domain noun. `_mod` and `_module` suffixes are forbidden. If a local symbol collides with the desired import name, rename the local symbol; the import keeps the clean name.
- Prefer a top-level type alias when a file repeatedly uses one type from a module (`const Bdf = bdf.Bdf;`). Keep the module import alongside when several declarations from the same module are referenced.
- Within a group, use dependency order when it improves reading flow; otherwise sort by alias name. Omit any group with no members; do not leave a blank line for an absent group. Do not add comments that merely label these groups.
- Capability-ID aliases use `Id` when a file handles one ID family, or `StandardId`/`ExtendedId` when both families occur. These are local aliases; do not add redundant public ID exports.
- Prefer direct BitField namespaces. When domain helpers require a wrapper, keep its schema in a private `const Fields` inside the owner rather than a file-level schema.
- Prefer native partial Word literals when the expected type is clear. Use `Owner.init(values)` for named construction and `Owner.from(raw)`/`raw()` for conversion. Keep mutations of observed values; collapse initialization-only assignments into literals.
- Keep native packed BAR types and their instance methods. Do not introduce BitField wrappers or raw/Word conversion chains solely for implementation uniformity.

## Comments

Use the baseline comment and module-header rules in `docs/guidelines/zig.md`.

zpci additions:

- Module-header (`//!`) and exported-item (`///`) doc comments are one short paragraph at most. Lead with the load-bearing fact. No ceremony, marketing language, or emoji.
- Default to no comment. Add a `///` doc comment only when the type signature does not carry what the caller needs: ownership, lifetime, units, invariants, allocation behavior, ordering, error conditions, or why the obvious alternative is wrong.
- API links inside comments cite paths under `docs/api/` only. Planning paths under `docs/planning/` rot and are not cited from source.

## Within-file declaration order

Source files read top-down:

1. module header doc-comment (`//!`);
2. import groups (above);
3. constants, public types, and operation families;
4. private helpers;
5. source-local `unit` last; [testing guidelines](testing.md) define its internal order.

Put constants above type definitions; place offset and metadata namespaces below
the primary types they describe. Keep canonical field order and authoritative
offset definitions independent of declaration order.

Inside register types, group encoded fields, value/conversion helpers, mask interfaces and classifications, then layout checks. Keep contextual mask-policy methods beside the related mask metadata. Source-local `unit` remains last.

## Compile-time assertions

`comptime` assertions about a type's size, alignment, field offsets, or packed-bit widths live in a single `comptime { ... }` block at the **end of the type body**, after every field and declaration. One block per type; not interleaved with fields.

File-level `comptime` blocks remain valid for assertions that are not type-owned.

Handwritten config-space `extern struct` and packed flag/bit words carry colocated assertions for size, alignment and mandated field positions. Multi-byte config fields are little-endian. Generated layouts instead use the generator's checks and independent PCI byte fixtures.

Do not repeat BitField backing-word or layout.Struct size/alignment guarantees in separate assertion blocks. Keep independent byte fixtures for the PCI encoding. Do not add handwritten mask forwarding or duplicate field lists.

## Public API discipline

- Make I/O, allocation, synchronization, and platform assumptions explicit.
- Reuse `ConfigSpace`/`Function` and `BarMemory` access seams rather than adding
  independent callback fields to every handle.
- Do not introduce generic device/driver/capability registries or device-type vtables.
- Preserve requested access widths; do not synthesize wider backend transactions
  or implicit read-modify-write operations.
- Follow [typed-offset and wire policies](../api/core.md) and the owning operation's
  validation/programming contract rather than repeating checks at every boundary.
- Update every caller after a rename; leave no compatibility aliases.

## Naming

Use the baseline Zig casing rules, with PCI acronyms treated as words in type
names: `Bdf`, `Sbdf`, `Msi`, `Msix`, `Ecam`, `Pio`.

- Names identify the operation: `read`, `vendorId`, `format`, `probe`.
- Name iterators for their result or traversal, such as `children` and `preorder`;
  use `next()` to advance them.
- Prefer positive predicates where clear; retain conventional names such as
  `isEmpty()` when a constructor already occupies `empty()`.

## Constructors

Use `from` for infallible construction and `tryFrom` for checked construction.
Qualify alternate inputs only when needed; keep parsers, discovery, and named
conversions distinct (`parse`, `find`, `fromBdf`, `fromCount`).

- `from` performs no validation I/O. It may rely on caller-proven invariants;
  [typed offsets](../api/core.md) are one such trusted constructor.
- Validate untrusted wider integers before narrowing; `@intCast` is not recoverable
  input validation.
- Use `deinit` for owned resources and explicit allocators for variable-sized output.
  Small bounded results may use inline storage. Do not add parallel scratch APIs.
- Use `Args` for ephemeral argument bundles; reserve `Options` for compile-time
  choices that shape a generated type.

## Error vocabulary

Reuse established error names for equivalent conditions. Each operation or checked representation conversion owns its narrow error set; there is no package-wide error union.

Rules:

- Error variant names describe the violated invariant, not the failing operation.
- Type-local error sets stay narrow. Add allocator errors only to APIs that allocate; compose cross-domain orchestration sets explicitly.
- Primitive errors from zstdx byte/range helpers and zpci identifier parsing are mapped into the owning module's domain error before crossing a public boundary; raw primitive errors are not part of any public domain surface.
- Public APIs do not expose `anyerror`. Orchestration that fans across domains unions the type-local sets explicitly.

## Error placement

Place error sets at the owning module or type; separate operation families when
their contracts differ. Canonical conversions do not import programming or routing
policy. Use the producing API's error set rather than forwarding catalogues or
unused umbrella aliases.

## Validation vs assertion

- Checked APIs reject malformed hardware/input with typed errors.
- Assertions enforce caller requirements and internal invariants, including trusted
  construction; they do not require a preceding validation call.
- Do not use assertions as recoverable validation of untrusted data.

## Checked-in generated source

`src/` is handwritten; compile-time layout/BitField generation is allowed.
Checked-in generated fixtures or manifests stay outside `src/` and include a
regeneration command.
