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
    .{ "script", {} },   .{ "style", {} },
    .{ "textarea", {} }, .{ "title", {} },
});

pub const RenderError = error{
    OutOfMemory,
    WriteFailed,
};

/// Render a node and all descendants as HTML to the given writer.
pub fn render(writer: std.io.AnyWriter, node: *const Node) anyerror!void {
    switch (node.node_type) {
        .document => {
            try renderChildren(writer, node);
        },
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

            if (void_elements.has(node.data)) {
                try writer.writeAll(">");
                return;
            }

            try writer.writeAll(">");
            try renderChildren(writer, node);
            try writer.writeAll("</");
            try writer.writeAll(node.data);
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

/// Render only the children of a node (inner HTML).
pub fn renderChildren(writer: std.io.AnyWriter, node: *const Node) anyerror!void {
    var child = node.first_child;
    while (child) |c| {
        try render(writer, c);
        child = c.next_sibling;
    }
}

/// Render a node to an allocated string.
pub fn renderToString(allocator: std.mem.Allocator, node: *const Node) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try render(buf.writer(allocator).any(), node);
    return buf.toOwnedSlice(allocator);
}

/// Render children to an allocated string (inner HTML).
pub fn renderChildrenToString(allocator: std.mem.Allocator, node: *const Node) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try renderChildren(buf.writer(allocator).any(), node);
    return buf.toOwnedSlice(allocator);
}

fn writeEscapedText(writer: std.io.AnyWriter, text: []const u8) anyerror!void {
    for (text) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(c),
        }
    }
}

fn writeEscapedAttr(writer: std.io.AnyWriter, text: []const u8) anyerror!void {
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
    try writeEscapedText(buf.writer(allocator).any(), text);
    return buf.toOwnedSlice(allocator);
}

test "render element" {
    const tree_m = @import("tree.zig");

    var parent = Node{ .node_type = .element, .data = "div", .attr = @constCast(&[_]node_mod.Attribute{
        .{ .key = "id", .val = "main" },
    }) };
    var child = Node{ .node_type = .text, .data = "hello" };
    tree_m.appendChild(&parent, &child);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try render(buf.writer(std.testing.allocator).any(), &parent);
    try std.testing.expectEqualStrings("<div id=\"main\">hello</div>", buf.items);
}

test "render void element" {
    var node = Node{ .node_type = .element, .data = "br", .attr = @constCast(&[_]node_mod.Attribute{}) };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try render(buf.writer(std.testing.allocator).any(), &node);
    try std.testing.expectEqualStrings("<br>", buf.items);
}

test "render escaping" {
    var node = Node{ .node_type = .text, .data = "a < b & c > d" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try render(buf.writer(std.testing.allocator).any(), &node);
    try std.testing.expectEqualStrings("a &lt; b &amp; c &gt; d", buf.items);
}
