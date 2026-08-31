const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const Selection = @import("selection.zig").Selection;
const Selector = @import("css/selector.zig").Selector;
const CompiledSelector = @import("css/compiled.zig").CompiledSelector;
const Matcher = @import("css/matcher.zig").Matcher;
const css_parser = @import("css/parser.zig");

/// A scratch arena for querying a document.
///
/// A `Document` owns its DOM and nothing else. Everything a query produces --
/// node slices, chained `Selection` states, parsed selector ASTs, and the
/// strings returned by `html()`, `text()` and `outerHtml()` -- belongs to a
/// `Query` instead, and is released together when the `Query` is deinitialized
/// or reset.
///
/// This is what makes a long-lived document viable. Previously every query
/// allocated into the document's own arena and nothing was ever released, so a
/// scraper holding one document and running queries against it grew without
/// bound: 2000 queries took a 43 MB document to 243 MB.
///
///     var doc = try Document.initFromSlice(gpa, html);
///     defer doc.deinit();
///
///     var q = doc.query(gpa);
///     defer q.deinit();
///
///     const links = try q.find("a.link");
///
/// A `Query` borrows its `Document`, so the document must outlive it. Because
/// the arena is stored inline, a `Query` must not be moved once a `Selection`
/// refers to it -- keep it in a local or on the heap, not in a container that
/// reallocates.
pub const Query = struct {
    doc: *Document,
    arena: std.heap.ArenaAllocator,
    /// Parsed selectors, keyed by source text. Repeating a selector in a loop
    /// is the common case and used to re-parse and re-allocate every time.
    selector_cache: std.StringHashMapUnmanaged(*const Selector) = .empty,

    pub fn init(doc: *Document, backing: Allocator) Query {
        return .{ .doc = doc, .arena = std.heap.ArenaAllocator.init(backing) };
    }

    /// Release every allocation made by this query. All `Selection` values and
    /// all strings obtained through it become invalid.
    pub fn deinit(self: *Query) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Release query allocations but keep the arena's capacity, so the next
    /// round of queries reuses the same memory. Use this when looping over
    /// many queries against one document.
    ///
    /// As with `deinit`, every `Selection` and every string obtained from this
    /// query before the reset becomes invalid.
    pub fn reset(self: *Query) void {
        _ = self.arena.reset(.retain_capacity);
        // The map's own storage came from the arena, so it is already gone.
        self.selector_cache = .empty;
    }

    /// Allocator for query results and temporaries. Freed by `deinit`/`reset`.
    pub fn scratch(self: *Query) Allocator {
        return self.arena.allocator();
    }

    /// Allocator for content that joins the DOM and must outlive this query --
    /// nodes, attribute keys and values, parsed fragments. Freed only when the
    /// document is.
    pub fn docAlloc(self: *Query) Allocator {
        return self.doc.domAllocator();
    }

    /// A selection containing just the document root.
    pub fn root(self: *Query) !Selection {
        return Selection.initSingle(self.doc.root_node, self);
    }

    /// Find elements matching a CSS selector, starting from the document root.
    pub fn find(self: *Query, selector: []const u8) !Selection {
        return (try self.root()).find(selector);
    }

    /// Find elements using a pre-built matcher.
    pub fn findMatcher(self: *Query, m: Matcher) !Selection {
        return (try self.root()).findMatcher(m);
    }

    /// Find elements using a reusable compiled selector.
    pub fn findCompiled(self: *Query, compiled: *const CompiledSelector) !Selection {
        return (try self.root()).findCompiled(compiled);
    }

    /// Parse a selector, reusing the result if this query has seen it before.
    pub fn compile(self: *Query, selector: []const u8) !*const Selector {
        if (self.selector_cache.get(selector)) |cached| return cached;

        const alloc = self.scratch();
        // The cache outlives the caller's slice, so both key and parsed AST
        // have to reference arena-owned text.
        const owned = try alloc.dupe(u8, selector);
        const parsed = try css_parser.parseSelector(alloc, owned);
        try self.selector_cache.put(alloc, owned, parsed);
        return parsed;
    }

    /// Bytes currently held by this query's arena.
    pub fn bytesUsed(self: *const Query) usize {
        return self.arena.queryCapacity();
    }
};
