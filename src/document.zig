const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("dom/node.zig").Node;
const NodeType = @import("dom/node.zig").NodeType;
const html_parser = @import("dom/parser.zig");
const tree = @import("dom/tree.zig");
const Selection = @import("selection.zig").Selection;

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

    /// Construct a Document that wraps an existing root node.
    /// The caller is responsible for the node's lifetime matching
    /// the backing allocator.
    pub fn initFromNode(backing: Allocator, root: *Node) Document {
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
            .url = self.url,
        };
    }

    /// Release all memory owned by this document.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// Root selection spanning the document's root node.
    pub fn select(self: *Document) Selection {
        return Selection.initSingle(self.root_node, self);
    }

    /// Convenience: parse a CSS selector and return matching elements.
    pub fn find(self: *Document, selector: []const u8) !Selection {
        return self.select().find(selector);
    }

    /// Convenience: find using a pre-compiled matcher.
    pub fn findMatcher(self: *Document, m: anytype) Selection {
        return self.select().findMatcher(m);
    }

    /// Arena allocator for this document. Selections allocate node slices here.
    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }
};

test "Document initFromSlice" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>Hello</p></div>");
    defer doc.deinit();
    try std.testing.expect(doc.root_node.node_type == .document);
}

test "Document find" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>Hello</p><p>World</p></div>");
    defer doc.deinit();
    const sel = try doc.find("p");
    try std.testing.expect(sel.len() == 2);
}
