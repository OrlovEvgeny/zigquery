const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("dom/node.zig").Node;
const NodeType = @import("dom/node.zig").NodeType;
const html_parser = @import("dom/parser.zig");
const tree = @import("dom/tree.zig");
const Query = @import("query.zig").Query;

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root_node: *Node,
    url: ?[]const u8 = null,

    /// Parse an HTML string into a Document. All DOM allocations live in
    /// the document's arena; call `deinit` to release everything at once.
    pub fn initFromSlice(backing: Allocator, html: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const root = try html_parser.parse(arena.allocator(), html);
        return .{ .arena = arena, .root_node = root };
    }

    /// Construct an owning Document by deep-cloning an existing root node.
    pub fn initFromNode(backing: Allocator, root: *const Node) !Document {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const cloned_root = try tree.cloneNode(arena.allocator(), root);
        return .{
            .arena = arena,
            .root_node = cloned_root,
        };
    }

    /// Wrap a borrowed root node. The caller must keep the complete source tree
    /// alive until this Document is deinitialized.
    pub fn initBorrowedNode(backing: Allocator, root: *Node) Document {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .root_node = root,
        };
    }

    /// Deep-clone the document.
    pub fn clone(self: *const Document, backing: Allocator) !Document {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const cloned_root = try tree.cloneNode(arena.allocator(), self.root_node);
        return .{
            .arena = arena,
            .root_node = cloned_root,
            .url = if (self.url) |url| try arena.allocator().dupe(u8, url) else null,
        };
    }

    /// Store a document URL in the document arena.
    pub fn setUrl(self: *Document, url: []const u8) !void {
        self.url = try self.domAllocator().dupe(u8, url);
    }

    /// Release all memory owned by this document.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// Open a query scope over this document.
    ///
    /// Query results live in the returned `Query`, not in the document, so
    /// releasing the query releases them. See `Query` for the rationale.
    ///
    ///     var q = doc.query(gpa);
    ///     defer q.deinit();
    ///     const links = try q.find("a.link");
    ///
    /// The document must outlive the query.
    pub fn query(self: *Document, backing: Allocator) Query {
        return Query.init(self, backing);
    }

    /// Allocator for the DOM itself.
    ///
    /// Reserved for content that becomes part of the document and must live as
    /// long as it does. Query results belong in `Query.scratch` instead.
    pub fn domAllocator(self: *Document) Allocator {
        return self.arena.allocator();
    }
};

test "Document initFromSlice" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>Hello</p></div>");
    defer doc.deinit();
    try std.testing.expect(doc.root_node.node_type == .document);
}

test "Document query" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>Hello</p><p>World</p></div>");
    defer doc.deinit();

    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    const sel = try q.find("p");
    try std.testing.expect(sel.len() == 2);
}

test "query allocations do not touch the document arena" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>a</p><p>b</p></div>");
    defer doc.deinit();

    const before = doc.arena.queryCapacity();

    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    for (0..500) |_| {
        const sel = try q.find("p");
        std.mem.doNotOptimizeAway(sel.len());
    }

    try std.testing.expectEqual(before, doc.arena.queryCapacity());
}

test "query reset reclaims without freeing the document" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>a</p><p>b</p></div>");
    defer doc.deinit();

    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    for (0..200) |_| {
        const sel = try q.find("p");
        std.mem.doNotOptimizeAway(sel.len());
    }
    const grown = q.bytesUsed();
    try std.testing.expect(grown > 0);

    q.reset();
    // Capacity is retained for reuse, and the document is untouched.
    try std.testing.expectEqual(@as(usize, 2), (try q.find("p")).len());
    try std.testing.expect(q.bytesUsed() <= grown);
}
