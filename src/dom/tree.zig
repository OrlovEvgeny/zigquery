const std = @import("std");
const Node = @import("node.zig").Node;
const NodeType = @import("node.zig").NodeType;
const Attribute = @import("node.zig").Attribute;

/// Bumped by every structural change to any tree.
///
/// Caches keyed on tree shape -- such as the sibling-position memo in the
/// selector matcher -- compare against this to notice they are stale without
/// having to track individual nodes. Reads never bump it, so a pure matching
/// pass keeps its caches.
pub var structure_generation: u64 = 0;

pub const MutationError = error{
    Cycle,
    InvalidReference,
};

pub const ValidationError = error{
    Cycle,
    InvalidParent,
    InvalidPreviousSibling,
    InvalidLastChild,
};

/// Remove a node from its parent, updating sibling links.
pub fn removeChild(parent: *Node, child: *Node) void {
    std.debug.assert(child.parent == parent);
    structure_generation +%= 1;

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
    std.debug.assert(!wouldCreateCycle(parent, new_child));
    structure_generation +%= 1;
    if (ref_child) |ref| {
        std.debug.assert(ref.parent == parent);
        if (ref == new_child) return;
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
    std.debug.assert(!wouldCreateCycle(parent, child));
    structure_generation +%= 1;
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

/// Insert a node while rejecting invalid references and ancestor cycles.
pub fn insertBeforeChecked(parent: *Node, new_child: *Node, ref_child: ?*Node) MutationError!void {
    if (ref_child) |ref| {
        if (ref.parent != parent) return error.InvalidReference;
    }
    if (wouldCreateCycle(parent, new_child)) return error.Cycle;
    insertBefore(parent, new_child, ref_child);
}

/// Append a node while rejecting ancestor cycles.
pub fn appendChildChecked(parent: *Node, child: *Node) MutationError!void {
    if (wouldCreateCycle(parent, child)) return error.Cycle;
    appendChild(parent, child);
}

fn wouldCreateCycle(parent: *const Node, child: *const Node) bool {
    if (parent == child) return true;

    // A childless node has no descendants, so it cannot be an ancestor of
    // `parent` -- only the identity case above could apply. Every node the
    // parser appends is freshly created, and `appendChild` asserts on this
    // function, whose argument is evaluated in every build mode including
    // ReleaseFast. Without this short-circuit the ancestor walk below runs
    // once per node and makes tree building O(nodes * depth).
    if (child.first_child == null) return false;

    var current = parent.parent;
    while (current) |ancestor| : (current = ancestor.parent) {
        if (ancestor == child) return true;
    }
    return false;
}

/// Next node in document order within `root`'s subtree, or null once the walk
/// is finished. `root` is the boundary: it is never returned, and the walk
/// never escapes above it.
///
/// This is the iterative replacement for the "recurse over every child"
/// pattern. Parent pointers make the climb possible without an auxiliary
/// stack, so a full-subtree walk costs no allocation and cannot overflow the
/// stack on deeply nested documents.
///
///     var cur: ?*Node = root.first_child;
///     while (cur) |n| : (cur = nextInPreorder(n, root)) { ... }
pub fn nextInPreorder(node: *Node, root: *const Node) ?*Node {
    if (node.first_child) |child| return child;
    var cur = node;
    while (cur != root) {
        if (cur.next_sibling) |sibling| return sibling;
        cur = cur.parent orelse return null;
    }
    return null;
}

/// `nextInPreorder` for read-only walks.
pub fn nextInPreorderConst(node: *const Node, root: *const Node) ?*const Node {
    if (node.first_child) |child| return child;
    var cur = node;
    while (cur != root) {
        if (cur.next_sibling) |sibling| return sibling;
        cur = cur.parent orelse return null;
    }
    return null;
}

/// Validate parent, sibling, and last-child links for a subtree.
///
/// Traversal follows only `first_child` and `next_sibling` and uses an explicit
/// stack: this function exists to find broken links, so it must not rely on the
/// parent pointers it is checking, and it must not recurse per level.
pub fn validate(allocator: std.mem.Allocator, root: *const Node) (ValidationError || std.mem.Allocator.Error)!void {
    var seen = std.AutoHashMap(*const Node, void).init(allocator);
    defer seen.deinit();

    var stack: std.ArrayList(*const Node) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);

    while (stack.pop()) |node| {
        if (seen.contains(node)) return error.Cycle;
        try seen.put(node, {});

        var previous: ?*Node = null;
        var child = node.first_child;
        while (child) |current| {
            if (current.parent != @constCast(node)) return error.InvalidParent;
            if (current.prev_sibling != previous) return error.InvalidPreviousSibling;
            try stack.append(allocator, current);
            previous = current;
            child = current.next_sibling;
        }
        if (node.last_child != previous) return error.InvalidLastChild;
    }
}

/// Copy one node's own data, without its children or tree links.
fn cloneShallow(allocator: std.mem.Allocator, original: *const Node) !*Node {
    const new_attrs = try allocator.alloc(Attribute, original.attr.len);
    for (original.attr, 0..) |attr, i| {
        new_attrs[i] = .{
            .namespace = try allocator.dupe(u8, attr.namespace),
            .key = try allocator.dupe(u8, attr.key),
            .val = try allocator.dupe(u8, attr.val),
        };
    }

    const node = try allocator.create(Node);
    node.* = .{
        .node_type = original.node_type,
        .data = try allocator.dupe(u8, original.data),
        .namespace = try allocator.dupe(u8, original.namespace),
        .attr = new_attrs,
        .parent = null,
        .first_child = null,
        .last_child = null,
        .prev_sibling = null,
        .next_sibling = null,
    };
    return node;
}

/// Deep-clone a node and all its descendants using the given arena.
///
/// Walks the source in document order while keeping a cursor into the copy, so
/// no stack frame is spent per level. The recursive version overflowed the
/// stack on deeply nested documents.
pub fn cloneNode(allocator: std.mem.Allocator, original: *const Node) !*Node {
    const root_clone = try cloneShallow(allocator, original);

    var src: *const Node = original;
    var dst: *Node = root_clone;

    while (true) {
        if (src.first_child) |child| {
            const child_clone = try cloneShallow(allocator, child);
            appendChild(dst, child_clone);
            src = child;
            dst = child_clone;
            continue;
        }

        // Climb in lockstep until there is a sibling to copy next.
        while (true) {
            if (src == original) return root_clone;

            if (src.next_sibling) |sibling| {
                const sibling_clone = try cloneShallow(allocator, sibling);
                appendChild(dst.parent.?, sibling_clone);
                src = sibling;
                dst = sibling_clone;
                break;
            }

            src = src.parent orelse return root_clone;
            dst = dst.parent orelse return root_clone;
        }
    }
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

    insertBefore(&parent, &child2, &child2);
    try std.testing.expect(child1.next_sibling == &child2);
    try std.testing.expect(child2.next_sibling == &child3);
    try validate(std.testing.allocator, &parent);
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

test "checked mutations reject cycles" {
    var parent = Node{ .node_type = .element, .data = "div" };
    var child = Node{ .node_type = .element, .data = "span" };
    appendChild(&parent, &child);

    try std.testing.expectError(error.Cycle, appendChildChecked(&child, &parent));
    try validate(std.testing.allocator, &parent);
}

test "validate detects broken sibling links" {
    var parent = Node{ .node_type = .element, .data = "div" };
    var child = Node{ .node_type = .element, .data = "span" };
    appendChild(&parent, &child);
    child.prev_sibling = &child;

    try std.testing.expectError(error.InvalidPreviousSibling, validate(std.testing.allocator, &parent));
}

test "nextInPreorder visits a subtree in document order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    //   root
    //   +- a
    //   |  +- b
    //   |  +- c
    //   +- d
    var root = Node{ .node_type = .element, .data = "root" };
    var a = Node{ .node_type = .element, .data = "a" };
    var b = Node{ .node_type = .element, .data = "b" };
    var c = Node{ .node_type = .element, .data = "c" };
    var d = Node{ .node_type = .element, .data = "d" };
    appendChild(&root, &a);
    appendChild(&a, &b);
    appendChild(&a, &c);
    appendChild(&root, &d);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(std.testing.allocator);

    var cur: ?*Node = root.first_child;
    while (cur) |n| : (cur = nextInPreorder(n, &root)) {
        try seen.appendSlice(std.testing.allocator, n.data);
    }
    try std.testing.expectEqualStrings("abcd", seen.items);
}

test "nextInPreorder does not escape above the boundary" {
    var root = Node{ .node_type = .element, .data = "root" };
    var a = Node{ .node_type = .element, .data = "a" };
    var b = Node{ .node_type = .element, .data = "b" };
    var sibling = Node{ .node_type = .element, .data = "sibling" };
    appendChild(&root, &a);
    appendChild(&a, &b);
    appendChild(&root, &sibling);

    // Walking `a`'s subtree must stop at `b` and not continue into `sibling`.
    var count: usize = 0;
    var cur: ?*Node = a.first_child;
    while (cur) |n| : (cur = nextInPreorder(n, &a)) {
        try std.testing.expectEqualStrings("b", n.data);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "nextInPreorder on a leaf yields nothing" {
    var leaf = Node{ .node_type = .element, .data = "leaf" };
    try std.testing.expect(leaf.first_child == null);
    try std.testing.expect(nextInPreorder(&leaf, &leaf) == null);
}

test "nextInPreorder walks a deep chain without recursing" {
    const gpa = std.testing.allocator;
    const depth = 50_000;
    const nodes = try gpa.alloc(Node, depth);
    defer gpa.free(nodes);
    for (nodes) |*n| n.* = .{ .node_type = .element, .data = "div" };
    for (nodes[1..], 0..) |*n, i| appendChild(&nodes[i], n);

    var count: usize = 0;
    var cur: ?*Node = nodes[0].first_child;
    while (cur) |n| : (cur = nextInPreorder(n, &nodes[0])) count += 1;
    try std.testing.expectEqual(@as(usize, depth - 1), count);
}
