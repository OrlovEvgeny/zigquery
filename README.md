# zigquery

jQuery-like HTML DOM manipulation library for Zig. Parse HTML, query elements with CSS selectors, traverse the tree, and manipulate the document
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

    // Find all paragraphs.
    const paragraphs = try doc.find("p");
    std.debug.print("Found {} paragraphs\n", .{paragraphs.len()});

    // Get text content.
    const title = try (try doc.find("h1")).text();
    std.debug.print("Title: {s}\n", .{title});

    // Read attributes.
    const link = try doc.find("a.active");
    const href = link.attr("href") orelse "";
    std.debug.print("Link: {s}\n", .{href});
}
```

## Installation

Add zigquery as a dependency in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/evgenyorlov/zigquery
```

Then in your `build.zig`:

```zig
const zigquery = b.dependency("zigquery", .{
    .target = target,
    .optimize = optimize,
});
module.addImport("zigquery", zigquery.module("zigquery"));
```

Requires **Zig 0.15.2** or later.

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
| `:has()` | `div:has(> p)` | Parent has matching descendant |
| `:contains()` | `p:contains("hello")` | Element contains text |
| `:first-child`, `:last-child`, `:only-child` | `li:first-child` | Structural pseudo-classes |
| `:first-of-type`, `:last-of-type`, `:only-of-type` | `p:first-of-type` | Type-based structural pseudo-classes |
| `:nth-child()`, `:nth-last-child()` | `tr:nth-child(2n+1)` | Positional with `an+b` formula |
| `:nth-of-type()`, `:nth-last-of-type()` | `p:nth-of-type(odd)` | Type-positional |
| `:empty`, `:root` | `div:empty` | Content / root pseudo-classes |
| `:enabled`, `:disabled`, `:checked` | `input:enabled` | Form pseudo-classes |

## API overview

### Document

```zig
// Parse HTML into a document. All allocations use an internal arena.
var doc = try zq.Document.initFromSlice(allocator, html);
defer doc.deinit();

// Query from the document root.
const sel = try doc.find("div.content");

// Deep-clone the entire document.
var copy = try doc.clone(allocator);
defer copy.deinit();
```

### Selection — Traversal

```zig
const sel = try doc.find("div");

// Descendants matching a selector.
const links = try sel.find("a");

// Direct children.
const kids = sel.children();
const filtered_kids = try sel.childrenFiltered("p");

// Parents.
const p = sel.parent();
const all_parents = sel.parents();
const until = sel.parentsUntil(.{ .selector = "body" });

// Closest ancestor (or self) matching a selector.
const wrapper = try sel.closest(".wrapper");

// Siblings.
const sibs = sel.siblings();
const next_el = sel.next();
const prev_all = sel.prevAll();
const next_until = sel.nextUntil(.{ .selector = "hr" });
```

### Selection — Filtering

```zig
const items = try doc.find("li");

const active = try items.filter(".active");
const inactive = try items.not(".active");
const with_links = try items.has("a");

const first = items.first();
const last = items.last();
const third = items.eq(2);        // zero-based
const from_end = items.eq(-1);    // negative indexes from end
const middle = items.sliceRange(1, 3);

// Boolean checks.
const is_active = items.is(".active");
```

### Selection — Properties

```zig
const el = try doc.find("a.nav");

// Attributes.
const href = el.attr("href");
const title = el.attrOr("title", "default");
el.setAttr("target", "_blank");
el.removeAttr("rel");

// Classes.
el.addClass("highlight bold");
el.removeClass("nav");
el.toggleClass("active");
const has = el.hasClass("highlight");

// Content.
const inner = try el.html();
const outer = try zq.outerHtml(el);
const txt = try el.text();
const name = zq.nodeName(el);
```

### Selection — Manipulation

```zig
const div = try doc.find("div");

// Insert content.
div.appendHtml("<p>appended</p>");
div.prependHtml("<p>prepended</p>");

// Insert around selection.
const p = try doc.find("p");
p.afterHtml("<hr/>");
p.beforeHtml("<!-- marker -->");

// Replace and remove.
_ = p.replaceWithHtml("<div>replaced</div>");
_ = p.remove();
_ = div.empty();   // remove all children

// Set content.
div.setHtml("<b>new content</b>");
div.setText("plain text");

// Wrap / unwrap.
div.wrapHtml("<section></section>");
div.unwrap();
```

### Selection — Iteration

```zig
const rows = try doc.find("tr");

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
const a = try doc.find(".foo");
const b = try doc.find(".bar");

const combined = try a.add(".bar");
const merged = a.addSelection(b);
const union_sel = a.@"union"(b);
const common = a.intersection(b);
```

## Running tests

```sh
zig build test
```

Inspired by Go's [goquery](https://github.com/PuerkitoBio/goquery) and, by extension, jQuery

## License
[MIT](LICENSE)
