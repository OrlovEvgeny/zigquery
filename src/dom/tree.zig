const std = @import("std");
const Node = @import("node.zig").Node;
const NodeType = @import("node.zig").NodeType;
const Attribute = @import("node.zig").Attribute;

/// Remove a node from its parent, updating sibling links.
pub fn removeChild(parent: *Node, child: *Node) void {
    std.debug.assert(child.parent == parent);

    if (child.prev_sibling) |prev| {
        prev.next_sibling = child.next_sibling;
    } else {
        parent.first_child = child.next_sibling;
    }

    if (child.next_sibling) |nxt| {
        nxt.prev_sibling = child.prev_sibling;
    } else {
        parent.last_child = child.prev_sibling;
    }

    child.parent = null;
    child.prev_sibling = null;
    child.next_sibling = null;
}

/// Detach a node from the tree (remove from parent if present).
pub fn detach(node: *Node) void {
    if (node.parent) |parent| {
        removeChild(parent, node);
    }
}

/// Insert `new_child` before `ref_child` under `parent`.
/// If `ref_child` is null, appends to end.
pub fn insertBefore(parent: *Node, new_child: *Node, ref_child: ?*Node) void {
    if (ref_child) |ref| {
        std.debug.assert(ref.parent == parent);
        detach(new_child);
        new_child.parent = parent;
        new_child.next_sibling = ref;
        new_child.prev_sibling = ref.prev_sibling;
        if (ref.prev_sibling) |prev| {
            prev.next_sibling = new_child;
        } else {
            parent.first_child = new_child;
        }
        ref.prev_sibling = new_child;
    } else {
        appendChild(parent, new_child);
    }
}

/// Append a child node to the end of parent's children.
pub fn appendChild(parent: *Node, child: *Node) void {
    detach(child);
    child.parent = parent;
    child.prev_sibling = parent.last_child;
    child.next_sibling = null;

    if (parent.last_child) |last| {
        last.next_sibling = child;
    } else {
        parent.first_child = child;
    }
    parent.last_child = child;
}

/// Deep-clone a node and all its descendants using the given arena.
pub fn cloneNode(allocator: std.mem.Allocator, original: *const Node) !*Node {
    const new_attrs = try allocator.alloc(Attribute, original.attr.len);
    @memcpy(new_attrs, original.attr);

    const node = try allocator.create(Node);
    node.* = .{
        .node_type = original.node_type,
        .data = original.data,
        .namespace = original.namespace,
        .attr = new_attrs,
        .parent = null,
        .first_child = null,
        .last_child = null,
        .prev_sibling = null,
        .next_sibling = null,
    };

    var it = original.childIterator();
    while (it.next()) |child| {
        const cloned_child = try cloneNode(allocator, child);
        appendChild(node, cloned_child);
    }

    return node;
}

/// Clone a slice of nodes.
pub fn cloneNodes(allocator: std.mem.Allocator, nodes: []*Node) ![]*Node {
    const result = try allocator.alloc(*Node, nodes.len);
    for (nodes, 0..) |n, i| {
        result[i] = try cloneNode(allocator, n);
    }
    return result;
}

/// Return the first child element node, skipping text/comment nodes.
pub fn getFirstChildElement(node: *const Node) ?*Node {
    var c = node.first_child;
    while (c) |child| {
        if (child.node_type == .element) return child;
        c = child.next_sibling;
    }
    return null;
}

test "appendChild and removeChild" {
    var parent = Node{ .node_type = .element, .data = "div" };
    var child1 = Node{ .node_type = .element, .data = "span" };
    var child2 = Node{ .node_type = .text, .data = "hello" };

    appendChild(&parent, &child1);
    appendChild(&parent, &child2);

    try std.testing.expect(parent.first_child == &child1);
    try std.testing.expect(parent.last_child == &child2);
    try std.testing.expect(child1.next_sibling == &child2);
    try std.testing.expect(child2.prev_sibling == &child1);
    try std.testing.expect(parent.childCount() == 2);

    removeChild(&parent, &child1);
    try std.testing.expect(parent.first_child == &child2);
    try std.testing.expect(parent.childCount() == 1);
    try std.testing.expect(child1.parent == null);
}

test "insertBefore" {
    var parent = Node{ .node_type = .element, .data = "div" };
    var child1 = Node{ .node_type = .element, .data = "a" };
    var child2 = Node{ .node_type = .element, .data = "b" };
    var child3 = Node{ .node_type = .element, .data = "c" };

    appendChild(&parent, &child1);
    appendChild(&parent, &child3);
    insertBefore(&parent, &child2, &child3);

    try std.testing.expect(parent.first_child == &child1);
    try std.testing.expect(child1.next_sibling == &child2);
    try std.testing.expect(child2.next_sibling == &child3);
    try std.testing.expect(parent.last_child == &child3);
}

test "cloneNode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parent = Node{ .node_type = .element, .data = "div" };
    var child = Node{ .node_type = .text, .data = "hello" };
    appendChild(&parent, &child);

    const cloned = try cloneNode(alloc, &parent);
    try std.testing.expectEqualStrings("div", cloned.data);
    try std.testing.expect(cloned.parent == null);
    try std.testing.expect(cloned.first_child != null);
    try std.testing.expectEqualStrings("hello", cloned.first_child.?.data);
    // Cloned nodes are distinct pointers.
    try std.testing.expect(cloned != &parent);
    try std.testing.expect(cloned.first_child.? != &child);
}
