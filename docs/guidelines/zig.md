# Zig engineering guidelines

This document sets the local defaults for Zig source. An approved specification or narrower project convention overrides these rules.

Priorities, in order: correctness and safety, predictable performance, developer experience. Prefer explicit, bounded designs over clever abstractions.

## Style

### Layout

- Run `zig fmt`.
- Use four spaces. Do not use hard tabs.
- Keep lines at or below 120 columns. Use trailing commas and let `zig fmt` wrap expressions, calls, literals, and type declarations.
- Use braces for every multi-line `if`, `while`, `for`, and `switch` body. A braceless body is allowed only when the whole construct fits on one line, contains one statement, and has no nested control flow.
- Use one blank line to separate declarations and logical statement groups. Do not use consecutive blank lines or decorative spacing.
- Put module imports and aliases at the head of a file. Group imports as `std`/`builtin`, external packages, then local modules. Follow imports with type aliases, value aliases, then function aliases. Separate non-empty groups with one blank line. Do not add comments that only name these groups.
- Order source from the most important declaration to supporting details. Within a type: fields, nested types, `const Self = @This();` when needed, `init`, then other methods. Move complex nested types to module scope.
- Group an acquisition with its matching `defer` or `errdefer`.
- Put a local binding immediately before the block that first uses it.
- Put a comment immediately before the declaration, statement, or block that it explains.

### Naming

- Use `TitleCase` for types and type factories, `camelCase` for functions and methods, and `snake_case` for variables, fields, files, directories, and namespaces.
- Capitalize acronyms in their conventional form. Use `VSRState`, `CPUID`, and `VMX`; do not write `VsrState`, `Cpuid`, or `Vmx`.
- Name domain concepts, ownership, lifetime, and units when they affect correctness. Put units and qualifiers last: `latency_ms_max`, `offset_bytes`.
- Use one term for one concept. Do not overload a name with context-dependent meanings.
- Prefer precise nouns. Avoid generic names such as `Data`, `Value`, `Context`, `Manager`, `Utils`, and `Misc`.
- Use names that reveal resource ownership: `gpa`, `arena`, `scratch`, or `pool`.
- Name related values symmetrically when they appear together: `source`/`target`, `start`/`end`.
- Do not create a second name for the same mutable state only to shorten an expression.
- Prefix a helper that serves one caller with the caller name when this clarifies the call chain.
- Use an options struct when same-typed arguments can be confused. Pass dependencies from general to specific. Put callbacks last.

### Comments and documentation

- Write a comment only for an invariant, hazard, external constraint, ownership rule, non-obvious contract, or rationale.
- State why the code has its form. Do not narrate visible control flow or repeat a signature.
- Keep prose terse and factual. Prefer one load-bearing sentence.
- Use complete sentences in full-line comments. End-of-line comments may be fragments.
- Use consistent labelled contract lines when they improve scanning: `Requirements:`, `Ordering:`, `Effects:`, `Returns:`, `Faults:`, or `Clobbers:`.
- Document public behavior that the type and signature cannot express: allocation, ownership, invalidation, waiting, capacity, concurrency, ordering, and errors.
- Do not retain changelog notes, process narration, task references, TODOs, commented-out code, or decorative banners in landed source.
- Give each non-trivial test a one-line description of its goal and method.

## Engineering

### Design, modules, and APIs

- Approved specifications define public behavior. Resolve an unclear public contract before implementation.
- Give each file one concept or type family. Keep dependency direction explicit. Keep facades as re-exports and aliases only.
- Do not introduce catch-all modules, registries, object systems, or vtables without a defined need.
- Put constructors and operations on the type they serve. Use `Type.init` for non-allocating construction unless a narrower convention applies.
- Do not hide allocation, I/O, synchronization, architecture probing, or privileged operations behind a pure-looking API.
- Update every caller after a rename. Do not retain compatibility aliases unless the specification requires them.
- Prefer the simplest return type that represents the contract without pushing avoidable branching into callers.

### Safety, bounds, and errors

- Use simple, explicit control flow. Do not use recursion in hot, critical, or bounded code.
- Give every loop and queue a clear bound, an asserted bound, or an explicit intentional non-termination contract.
- State invariants positively. Split complex boolean decisions into named facts or nested branches.
- A function fits the screen. The hard limit is 80 lines, including the signature and closing brace. Pure data tables and generated literals are exempt when noted.
- Keep variables in the smallest useful scope. Compute and validate values near their use.
- Assert preconditions, postconditions, and internal invariants. Assertions detect programmer errors; explicit errors handle operating failures.
- Use at least two assertions in each non-trivial function. Pair assertions across boundaries such as writer/reader and caller/callee. Assert both valid and impossible input spaces.
- Put compile-time assertions next to the type or constant relationship that they protect.
- Handle, translate, or propagate every error. Use narrow error sets at module boundaries. Use `catch unreachable` only with local proof.

### Types, memory, and concurrency

- Use fixed-width integers for persisted, ABI, wire, and cross-platform data. Use `usize` only for host-memory sizes, indexes, and pointer-width APIs.
- Treat indexes, counts, sizes, addresses, offsets, IDs, and handles as distinct concepts. Use strong types or names with units where mixing them is unsafe.
- Make integer-division rounding explicit with `@divExact`, `@divFloor`, `@divTrunc`, or `divCeil`.
- Keep casts and narrowing conversions at the boundary that proves them valid.
- Make allocation behavior part of the API contract. Do not allocate in hot paths, callbacks, dispatch loops, or failure paths unless the contract permits it.
- Prefer caller-provided storage, fixed buffers, bounded containers, and immutable precomputed tables when bounds are known.
- Put `defer` or `errdefer` immediately after acquisition.
- Pass immutable values of 16 bytes or more by `*const` when an accidental copy would be incorrect or expensive. Construct large pointer-stable values in place.
- State the access model and progress guarantee for concurrent APIs. Name atomic memory ordering at each operation. Do not hide blocking, sleeping, spinning, or waiting.

### Performance

- Estimate CPU, memory, disk, and network cost during design. Consider both latency and bandwidth.
- Optimize the slowest frequently used resource first.
- Separate control-plane work from data-plane work. Batch work to amortize fixed costs.
- Keep hot paths predictable: direct data layout, bounded work, predictable branches, and predictable memory access.
- Avoid avoidable allocation, copying, formatting, syscalls, locks, and indirect dispatch in hot paths.
- Extract hot loops into small stand-alone functions with primitive arguments when this makes data flow and cost visible.
- Make overflow, wrapping, saturation, and rounding intent explicit. Do not accept cleverness only because it wins one benchmark.

### Verification

- Test observable behavior and invariants, including valid inputs, invalid inputs, boundaries, public errors, and transitions between valid and invalid states.
- Test public allocation, waiting, invalidation, ordering, and concurrency contracts.
- Compare optimized implementations with a simple reference model when practical.
- Put ABI and layout assertions with the type. Gate target-, hardware-, and privilege-specific tests when their prerequisites are unavailable.
- Do not ship placeholders, fake fallbacks, or known violations of the approved contract.
