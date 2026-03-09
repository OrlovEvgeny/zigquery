const std = @import("std");

pub const NodeType = enum(u4) {
    element,
    text,
    comment,
    doctype,
    document,
};

pub const Attribute = struct {
    namespace: []const u8 = "",
    key: []const u8,
    val: []const u8,
};

pub const Node = struct {
    node_type: NodeType,
    data: []const u8,
    namespace: []const u8 = "",
    attr: []Attribute = &.{},
    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    prev_sibling: ?*Node = null,
    next_sibling: ?*Node = null,

    /// Attribute lookup by key. Returns the value if found.
    pub fn getAttr(self: *const Node, key: []const u8) ?[]const u8 {
        for (self.attr) |a| {
            if (std.mem.eql(u8, a.key, key)) return a.val;
        }
        return null;
    }

    /// Attribute lookup including namespace.
    pub fn getAttrNs(self: *const Node, namespace: []const u8, key: []const u8) ?[]const u8 {
        for (self.attr) |a| {
            if (std.mem.eql(u8, a.key, key) and std.mem.eql(u8, a.namespace, namespace)) return a.val;
        }
        return null;
    }

    /// Iterate over children from first to last.
    pub fn childIterator(self: *const Node) ChildIterator {
        return .{ .current = self.first_child };
    }

    pub const ChildIterator = struct {
        current: ?*Node,

        pub fn next(self: *ChildIterator) ?*Node {
            const node = self.current orelse return null;
            self.current = node.next_sibling;
            return node;
        }
    };

    /// Count of direct children.
    pub fn childCount(self: *const Node) usize {
        var count: usize = 0;
        var it = self.childIterator();
        while (it.next()) |_| count += 1;
        return count;
    }

    /// Walk from this node to root, returning depth.
    pub fn depth(self: *const Node) usize {
        var d: usize = 0;
        var cur = self.parent;
        while (cur) |p| : (d += 1) {
            cur = p.parent;
        }
        return d;
    }
};

test "node attribute lookup" {
    const attrs = [_]Attribute{
        .{ .key = "id", .val = "main" },
        .{ .key = "class", .val = "container" },
    };
    const node = Node{
        .node_type = .element,
        .data = "div",
        .attr = @constCast(&attrs),
    };
    try std.testing.expectEqualStrings("main", node.getAttr("id").?);
    try std.testing.expectEqualStrings("container", node.getAttr("class").?);
    try std.testing.expect(node.getAttr("href") == null);
}
