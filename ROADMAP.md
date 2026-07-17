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

## v0.3 - parser conformance

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

## v0.5 - performance and tooling

- Benchmarks for parsing, matching, rendering, cloning, and bulk mutation.
- Fuzz targets for HTML/CSS parsers and mutation sequences with tree validation.
- Selector planning indexes for IDs/classes/tags and reduced temporary allocations.
- Streaming writer APIs and configurable serialization modes.

## v1.0 - stable contract

- Freeze ownership, error, allocator, and mutation semantics.
- Publish compatibility and security policies plus a semver deprecation process.
- Require conformance, fuzz, benchmark-regression, and cross-platform release gates.
- Document supported HTML/CSS standards and all deliberate deviations.
