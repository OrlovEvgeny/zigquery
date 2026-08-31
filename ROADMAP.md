# Roadmap

zigquery is moving toward a stable 1.0 API in compatibility-focused stages. Runtime
dependencies remain at zero, and supported Zig versions are tested explicitly.

## v0.2 - correctness and ownership

- Owning documents, fragments, attributes, URLs, and deep clones.
- Explicit allocation errors across traversal and mutation APIs.
- Atomic multi-target mutations and source-preserving node insertion.
- Correct RCDATA/numeric references, common optional end tags, and document structure.
- Relative `:has()`, selector lists in `:not()`/`:is()`/`:where()`, and strict parsing.
- Reusable `CompiledSelector`, tree validation, and Zig 0.15.2/0.16.x CI.

## v0.3 - ownership and complexity (current)

Done:

- `Query` scratch arena: query results, chained selections, parsed selectors and
  returned strings live and die with the query, not the document. Repeated
  queries against a long-lived document no longer grow it.
- Removed the quadratic paths found by the benchmark harness:
  `wouldCreateCycle` under an `assert` (evaluated in every build mode) made tree
  building O(nodes x depth); `autoClose` scanned the whole open-element stack per
  start tag; `:has()` re-scanned the entire document per anchor; `:nth-child()`
  recounted a sibling list per candidate.
- Iterative traversal for render, clone, validate, text extraction and matching,
  so deeply nested documents no longer overflow the stack.
- Benchmark harness (`zig build bench`) with deterministic corpora, per-operation
  memory accounting, and an empirical complexity check (`--scaling`).

Remaining for parser conformance, deferred to v0.4:

- Replace ad hoc tree construction with explicit WHATWG insertion modes.
- Add foster parenting, template modes, foreign SVG/MathML content, and adoption agency.
- Generate the complete named character reference table from WHATWG data.
- Import focused html5lib tree-construction fixtures and differential serialization tests.
- Add streaming `Reader` input while preserving the slice convenience API.

## v0.4 - selector coverage

- CSS escapes, namespaces, `:lang()`, `:dir()`, and `of <selector>` in `:nth-child()`.
- Forgiving selector lists where required by Selectors Level 4.
- Selector specificity metadata and bounded matching for untrusted selectors.
- Conformance fixtures derived from Web Platform Tests.

## v0.5 - memory and tooling

- Reduce per-node footprint: pooled node allocation, exact-size attribute
  arrays, an interned namespace field, and coalesced text nodes. On a
  node-dense document the arena currently holds about 108 bytes per node
  against a 96-byte `Node`, so node size is essentially the whole cost there.
- Fuzz targets for HTML/CSS parsers and mutation sequences with tree validation.
- Streaming writer APIs and configurable serialization modes.
- Selector planning indexes for IDs/classes/tags, if profiling justifies them.
  Measured selector times are currently in the low hundreds of microseconds on
  a 2 MB document, so this is not yet the bottleneck it was assumed to be.

## v1.0 - stable contract

- Freeze ownership, error, allocator, and mutation semantics.
- Publish compatibility and security policies plus a semver deprecation process.
- Require conformance, fuzz, benchmark-regression, and cross-platform release gates.
- Document supported HTML/CSS standards and all deliberate deviations.
