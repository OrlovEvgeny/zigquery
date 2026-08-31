# zigquery

[![CI](https://github.com/OrlovEvgeny/zigquery/actions/workflows/ci.yml/badge.svg)](https://github.com/OrlovEvgeny/zigquery/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/OrlovEvgeny/zigquery)](https://github.com/OrlovEvgeny/zigquery/releases/latest)
[![Zig](https://img.shields.io/badge/Zig-0.15.2%20%7C%200.16.0-f7a41d?logo=zig)](https://ziglang.org/)

jQuery-like HTML DOM manipulation library for Zig. Parse HTML, query elements with CSS selectors, traverse the tree, and manipulate the document.
## Quick start

```zig
const std = @import("std");
const zq = @import("zigquery");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var doc = try zq.Document.initFromSlice(allocator,
        \\<html>
        \\  <body>
        \\    <div class="content">
        \\      <h1>Hello</h1>
        \\      <p>First paragraph</p>
        \\      <p>Second paragraph</p>
        \\      <a href="/about" class="active">About</a>
        \\    </div>
        \\  </body>
        \\</html>
    );
    defer doc.deinit();

    // A Query owns everything the queries below allocate.
    var q = doc.query(allocator);
    defer q.deinit();

    // Find all paragraphs.
    const paragraphs = try q.find("p");
    std.debug.print("Found {} paragraphs\n", .{paragraphs.len()});

    // Get text content.
    const title = try (try q.find("h1")).text();
    std.debug.print("Title: {s}\n", .{title});

    // Read attributes.
    const link = try q.find("a.active");
    const href = link.attr("href") orelse "";
    std.debug.print("Link: {s}\n", .{href});
}
```

## Installation

Add zigquery as a dependency in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/OrlovEvgeny/zigquery
```

If Zig reports an invalid fingerprint, make sure the repository owner is
`OrlovEvgeny` and rerun `zig fetch --save` with the corrected URL.

Then in your `build.zig`:

```zig
const zigquery = b.dependency("zigquery", .{
    .target = target,
    .optimize = optimize,
});
module.addImport("zigquery", zigquery.module("zigquery"));
```

Supported Zig versions: **0.15.2** and **0.16.x**.

## CSS selectors

Supported selector syntax:

| Selector | Example | Description |
|---|---|---|
| Type | `div`, `p`, `a` | Match by tag name |
| Class | `.active`, `.foo.bar` | Match by class (compound supported) |
| ID | `#main` | Match by ID |
| Universal | `*` | Match any element |
| Attribute | `[href]`, `[type="text"]` | Attribute existence / value |
| Attribute operators | `[class~="foo"]`, `[lang\|="en"]`, `[href^="/"]`, `[src$=".png"]`, `[data*="val"]` | Includes, dash-match, prefix, suffix, substring |
| Descendant | `div p` | `p` anywhere inside `div` |
| Child | `div > p` | Direct child only |
| Adjacent sibling | `h1 + p` | Immediately after |
| General sibling | `h1 ~ p` | Any sibling after |
| Group | `h1, h2, h3` | Match any in the list |
| Negation | `:not(.hidden)` | Exclude matches |
| Logical lists | `:is(h1, h2)`, `:where(.note)` | Match any selector in a list |
| `:has()` | `div:has(> p)` | Parent has matching descendant |
| `:contains()` | `p:contains("hello")` | Element contains text |
| `:first-child`, `:last-child`, `:only-child` | `li:first-child` | Structural pseudo-classes |
| `:first-of-type`, `:last-of-type`, `:only-of-type` | `p:first-of-type` | Type-based structural pseudo-classes |
| `:nth-child()`, `:nth-last-child()` | `tr:nth-child(2n+1)` | Positional with `an+b` formula |
| `:nth-of-type()`, `:nth-last-of-type()` | `p:nth-of-type(odd)` | Type-positional |
| `:empty`, `:root` | `div:empty` | Content / root pseudo-classes |
| `:enabled`, `:disabled`, `:checked` | `input:enabled` | Form pseudo-classes |

## API overview

### Document and Query

A `Document` owns the parsed DOM. A `Query` owns everything a query produces:
node slices, chained `Selection` states, parsed selectors, and the strings
returned by `html()`, `text()` and `outerHtml()`.

```zig
// Parse HTML into a document. The DOM lives in the document's arena.
var doc = try zq.Document.initFromSlice(allocator, html);
defer doc.deinit();

// Open a query scope. Results live here, not in the document.
var q = doc.query(allocator);
defer q.deinit();

const sel = try q.find("div.content");

// Deep-clone the entire document.
var copy = try doc.clone(allocator);
defer copy.deinit();
```

Keeping the two apart is what makes a long-lived document practical. When you
run many queries against one document -- a scraper looping over pages, or a
server handling requests -- reclaim between rounds:

```zig
var q = doc.query(allocator);
defer q.deinit();

for (jobs) |job| {
    const rows = try q.find(job.selector);
    try handle(rows);
    q.reset();   // releases this round's results, keeps the capacity
}
```

`q.reset()` and `q.deinit()` invalidate every `Selection` and every string
obtained through that query. Anything you need to keep, copy out first.

Changes you make to the DOM are not query data and are unaffected: attributes,
inserted nodes and parsed fragments belong to the document and outlive the
query that created them.

All the examples below assume a `q` in scope, as above.

### Selection — Traversal

```zig
const sel = try q.find("div");

// Descendants matching a selector.
const links = try sel.find("a");

// Direct children.
const kids = try sel.children();
const filtered_kids = try sel.childrenFiltered("p");

// Parents.
const p = try sel.parent();
const all_parents = try sel.parents();

// Closest ancestor (or self) matching a selector.
const wrapper = try sel.closest(".wrapper");

// Siblings.
const sibs = try sel.siblings();
const next_el = try sel.next();
const prev_all = try sel.prevAll();
```

### Selection — Filtering

```zig
const items = try q.find("li");

const active = try items.filter(".active");
const inactive = try items.not(".active");
const with_links = try items.has("a");

const first = try items.first();
const last = try items.last();
const third = try items.eq(2);        // zero-based
const from_end = try items.eq(-1);    // negative indexes from end
const middle = try items.sliceRange(1, 3);

// Boolean checks.
const is_active = try items.is(".active");
```

### Selection — Properties

```zig
const el = try q.find("a.nav");

// Attributes.
const href = el.attr("href");
const title = el.attrOr("title", "default");
try el.setAttr("target", "_blank");
el.removeAttr("rel");

// Classes.
try el.addClass("highlight bold");
try el.removeClass("nav");
try el.toggleClass("active");
const has = el.hasClass("highlight");

// Content.
const inner = try el.html();
const outer = try zq.outerHtml(el);
const txt = try el.text();
const name = zq.nodeName(el);
```

### Selection — Manipulation

```zig
const div = try q.find("div");

// Insert content.
try div.appendHtml("<p>appended</p>");
try div.prependHtml("<p>prepended</p>");

// Insert around selection.
const p = try q.find("p");
try p.afterHtml("<hr/>");
try p.beforeHtml("<!-- marker -->");

// Replace and remove.
_ = try p.replaceWithHtml("<div>replaced</div>");
_ = p.remove();
_ = try div.empty();   // remove all children

// Set content.
try div.setHtml("<b>new content</b>");
try div.setText("plain text");

// Wrap / unwrap.
try div.wrapHtml("<section></section>");
try div.unwrap();
```

### Selection — Iteration

```zig
const rows = try q.find("tr");

// Iterator (idiomatic Zig).
var it = rows.iterator();
while (it.next()) |row| {
    const cells = try row.find("td");
    // ...
}

// Callback-based.
rows.each(struct {
    fn f(i: usize, sel: zq.Selection) void {
        _ = i;
        _ = sel;
    }
}.f);
```

### Selection — Set operations

```zig
const a = try q.find(".foo");
const b = try q.find(".bar");

const combined = try a.add(".bar");
const merged = try a.addSelection(b);
const union_sel = try a.@"union"(b);
const common = try a.intersection(b);
```

### Compiled selectors

Compile a selector once when it is reused across queries or documents:

```zig
var active_links = try zq.CompiledSelector.init(allocator, "a.active");
defer active_links.deinit();

const links = try q.findCompiled(&active_links);
const matches = links.isCompiled(&active_links);
```

## Ownership and errors

Two arenas, with a clear division:

| Lives in the **document** arena | Lives in the **query** arena |
|---|---|
| Parsed nodes and their data | `Selection.nodes` slices |
| Attribute keys and values you set | Chained selection state (`end()`, `addBack()`) |
| Nodes from `appendHtml`, `setHtml`, `wrapHtml`, … | Parsed selector ASTs |
| Clones from `cloneSel` | Strings from `html()`, `text()`, `outerHtml()` |
| Released by `doc.deinit()` | Released by `q.deinit()` or `q.reset()` |

Input buffers and source documents may be released once parsing completes. Use
`Document.initBorrowedNode` only when the source tree is guaranteed to outlive
the document. A `Query` borrows its `Document`, so the document must outlive it.

Operations that allocate return an error union: traversal methods such as
`children`, positional methods such as `first`, attribute and class updates, and
DOM mutations. Mutations parse or clone all required data before changing the
tree, so an allocation failure does not leave a partially updated selection.

## v0.3 migration

Queries now run through a `Query` rather than the `Document`:

```zig
// v0.2
const links = try doc.find("a.active");

// v0.3
var q = doc.query(allocator);
defer q.deinit();
const links = try q.find("a.active");
```

- `Document.find`, `findMatcher`, `findCompiled` and `select` move to `Query`
  (`select` is now `Query.root`).
- `Document.allocator` is renamed `Document.domAllocator` and is reserved for
  content that joins the DOM.
- `Selection.document` is now the method `Selection.document()`; the struct
  field is `Selection.q`.
- Strings from `html()`, `text()` and `outerHtml()` belong to the query and do
  not survive `q.deinit()` or `q.reset()`. Duplicate anything you need to keep.

Previously every query allocated into the document's arena and nothing was ever
released, so repeated queries against one document grew without bound.

## v0.2 migration

Add `try` to allocating `Selection` calls. Node insertion now deep-clones supplied nodes
for every destination and never detaches the caller's source nodes. Invalid selector
syntax is returned as an error by `Selection.is` instead of being treated as no match.

## Parser scope

The parser is intentionally lenient and covers common HTML document and fragment use,
including implicit `html/head/body`, raw text/RCDATA, optional closing for common list
and table elements, comments, and core character references. It is not yet a complete
WHATWG tree builder; foreign content, templates, the adoption agency algorithm, and the
full named entity table remain roadmap items. See [ROADMAP.md](ROADMAP.md).

## Running tests

```sh
zig build test
```

## Benchmarks

```sh
zig build bench                    # the standard suite, always ReleaseFast
zig build bench -- --scaling       # empirical complexity at 1x / 2x / 4x input
zig build bench -- --filter find/  # a subset
zig build bench -- --corpus <dir>  # also run against local .html files
```

Corpora are generated deterministically, so results are comparable across
machines. `--scaling` reports an exponent per workload: about 1.0 for linear,
2.0 for quadratic. `bench/baseline.json` records a reference run.

Inspired by Go's [goquery](https://github.com/PuerkitoBio/goquery) and, by extension, jQuery

## License
[MIT](LICENSE)
