const std = @import("std");
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeType = node_mod.NodeType;

const void_elements = std.StaticStringMap(void).initComptime(.{
    .{ "area", {} },  .{ "base", {} },  .{ "br", {} },
    .{ "col", {} },   .{ "embed", {} }, .{ "hr", {} },
    .{ "img", {} },   .{ "input", {} }, .{ "link", {} },
    .{ "meta", {} },  .{ "param", {} }, .{ "source", {} },
    .{ "track", {} }, .{ "wbr", {} },
});

const raw_text_elements = std.StaticStringMap(void).initComptime(.{
    .{ "script", {} }, .{ "style", {} }, .{ "xmp", {} },
});

/// Render a node and all descendants as HTML. The writer must provide
/// `writeAll([]const u8)` and `writeByte(u8)` methods returning error unions.
pub fn render(writer: anytype, node: *const Node) anyerror!void {
    return renderSubtree(writer, node, true);
}

/// Render only the children of a node (inner HTML).
pub fn renderChildren(writer: anytype, node: *const Node) anyerror!void {
    return renderSubtree(writer, node, false);
}

/// Walk `root` in document order, emitting each node's opening markup on the
/// way down and its closing tag on the way back up.
///
/// This is iterative on purpose. The obvious mutually recursive version costs
/// two stack frames per level of nesting and overflows the stack on deeply
/// nested documents -- 50 000 levels is well within what a hostile or merely
/// sloppy page can contain. Parent pointers make the climb possible without an
/// auxiliary stack, so rendering needs no allocation and no depth limit.
fn renderSubtree(writer: anytype, root: *const Node, comptime include_root: bool) anyerror!void {
    var cur: *const Node = if (include_root) root else (root.first_child orelse return);

    while (true) {
        try renderOpen(writer, cur);

        // A void element serializes as its start tag alone; if a malformed
        // tree gave it children, they are not part of its serialization.
        if (!isVoidElement(cur)) {
            if (cur.first_child) |child| {
                cur = child;
                continue;
            }
        }
        try renderClose(writer, cur);

        // Climb toward the root, closing each ancestor as we leave it, until
        // there is a sibling to move on to.
        while (true) {
            if (include_root and cur == root) return;

            if (cur.next_sibling) |sibling| {
                cur = sibling;
                break;
            }

            const parent = cur.parent orelse return;
            if (!include_root and parent == root) return;
            try renderClose(writer, parent);
            cur = parent;
        }
    }
}

/// Everything a node emits before its children: the whole node for leaves.
fn renderOpen(writer: anytype, node: *const Node) anyerror!void {
    switch (node.node_type) {
        .document => {},
        .element => {
            try writer.writeAll("<");
            try writer.writeAll(node.data);

            for (node.attr) |attr| {
                try writer.writeAll(" ");
                if (attr.namespace.len > 0) {
                    try writer.writeAll(attr.namespace);
                    try writer.writeAll(":");
                }
                try writer.writeAll(attr.key);
                try writer.writeAll("=\"");
                try writeEscapedAttr(writer, attr.val);
                try writer.writeAll("\"");
            }

            try writer.writeAll(">");
        },
        .text => {
            if (node.parent) |parent| {
                if (parent.node_type == .element and raw_text_elements.has(parent.data)) {
                    try writer.writeAll(node.data);
                    return;
                }
            }
            try writeEscapedText(writer, node.data);
        },
        .comment => {
            try writer.writeAll("<!--");
            try writer.writeAll(node.data);
            try writer.writeAll("-->");
        },
        .doctype => {
            try writer.writeAll("<!DOCTYPE ");
            try writer.writeAll(node.data);
            try writer.writeAll(">");
        },
    }
}

fn isVoidElement(node: *const Node) bool {
    return node.node_type == .element and void_elements.has(node.data);
}

/// The closing tag, for the nodes that have one.
fn renderClose(writer: anytype, node: *const Node) anyerror!void {
    if (node.node_type != .element) return;
    if (void_elements.has(node.data)) return;
    try writer.writeAll("</");
    try writer.writeAll(node.data);
    try writer.writeAll(">");
}

/// Render a node to an allocated string.
pub fn renderToString(allocator: std.mem.Allocator, node: *const Node) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var writer = ArrayListWriter{ .list = &buf, .allocator = allocator };
    try render(&writer, node);
    return buf.toOwnedSlice(allocator);
}

/// Render children to an allocated string (inner HTML).
pub fn renderChildrenToString(allocator: std.mem.Allocator, node: *const Node) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var writer = ArrayListWriter{ .list = &buf, .allocator = allocator };
    try renderChildren(&writer, node);
    return buf.toOwnedSlice(allocator);
}

fn writeEscapedText(writer: anytype, text: []const u8) anyerror!void {
    for (text) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(c),
        }
    }
}

fn writeEscapedAttr(writer: anytype, text: []const u8) anyerror!void {
    for (text) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Escape a string for safe HTML text content.
pub fn escapeString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var writer = ArrayListWriter{ .list = &buf, .allocator = allocator };
    try writeEscapedText(&writer, text);
    return buf.toOwnedSlice(allocator);
}

const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn writeAll(self: *ArrayListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    fn writeByte(self: *ArrayListWriter, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }
};

test "render element" {
    const tree_m = @import("tree.zig");

    var parent = Node{ .node_type = .element, .data = "div", .attr = @constCast(&[_]node_mod.Attribute{
        .{ .key = "id", .val = "main" },
    }) };
    var child = Node{ .node_type = .text, .data = "hello" };
    tree_m.appendChild(&parent, &child);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = ArrayListWriter{ .list = &buf, .allocator = std.testing.allocator };
    try render(&writer, &parent);
    try std.testing.expectEqualStrings("<div id=\"main\">hello</div>", buf.items);
}

test "render void element" {
    var node = Node{ .node_type = .element, .data = "br", .attr = @constCast(&[_]node_mod.Attribute{}) };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = ArrayListWriter{ .list = &buf, .allocator = std.testing.allocator };
    try render(&writer, &node);
    try std.testing.expectEqualStrings("<br>", buf.items);
}

test "render nested structure with mixed node types" {
    const tree_m = @import("tree.zig");

    var root = Node{ .node_type = .element, .data = "div" };
    var a = Node{ .node_type = .element, .data = "p" };
    var t1 = Node{ .node_type = .text, .data = "one" };
    var br = Node{ .node_type = .element, .data = "br" };
    var b = Node{ .node_type = .element, .data = "span" };
    var t2 = Node{ .node_type = .text, .data = "two" };
    var c = Node{ .node_type = .comment, .data = "note" };

    tree_m.appendChild(&root, &a);
    tree_m.appendChild(&a, &t1);
    tree_m.appendChild(&a, &br);
    tree_m.appendChild(&root, &b);
    tree_m.appendChild(&b, &t2);
    tree_m.appendChild(&root, &c);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = ArrayListWriter{ .list = &buf, .allocator = std.testing.allocator };
    try render(&writer, &root);
    try std.testing.expectEqualStrings(
        "<div><p>one<br></p><span>two</span><!--note--></div>",
        buf.items,
    );

    // Inner HTML skips the root's own tags but is otherwise identical.
    buf.clearRetainingCapacity();
    try renderChildren(&writer, &root);
    try std.testing.expectEqualStrings(
        "<p>one<br></p><span>two</span><!--note-->",
        buf.items,
    );
}

test "render deeply nested tree without recursing" {
    // The recursive implementation overflowed the stack here in Debug builds.
    const gpa = std.testing.allocator;
    const tree_m = @import("tree.zig");
    const depth = 50_000;

    const nodes = try gpa.alloc(Node, depth);
    defer gpa.free(nodes);
    for (nodes) |*n| n.* = .{ .node_type = .element, .data = "div" };
    for (nodes[1..], 0..) |*n, i| tree_m.appendChild(&nodes[i], n);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer = ArrayListWriter{ .list = &buf, .allocator = gpa };
    try render(&writer, &nodes[0]);

    try std.testing.expectEqual(@as(usize, depth), std.mem.count(u8, buf.items, "<div>"));
    try std.testing.expectEqual(@as(usize, depth), std.mem.count(u8, buf.items, "</div>"));
}

test "renderChildren of a leaf emits nothing" {
    var leaf = Node{ .node_type = .element, .data = "div" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = ArrayListWriter{ .list = &buf, .allocator = std.testing.allocator };
    try renderChildren(&writer, &leaf);
    try std.testing.expectEqualStrings("", buf.items);
}

test "render escaping" {
    var node = Node{ .node_type = .text, .data = "a < b & c > d" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = ArrayListWriter{ .list = &buf, .allocator = std.testing.allocator };
    try render(&writer, &node);
    try std.testing.expectEqualStrings("a &lt; b &amp; c &gt; d", buf.items);
}
