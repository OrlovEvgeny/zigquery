const std = @import("std");
const zq = @import("zigquery");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var doc = try zq.Document.initFromSlice(alloc, "<div><p>Hello</p><p>World</p></div>");
    defer doc.deinit();

    printTree(doc.root_node, 0);

    std.debug.print("\n--- find p ---\n", .{});
    const ps = try doc.find("p");
    std.debug.print("ps: {}\n", .{ps.len()});

    std.debug.print("\n--- find div ---\n", .{});
    const divs = try doc.find("div");
    std.debug.print("divs: {}\n", .{divs.len()});

    if (divs.len() > 0) {
        const ch = divs.children();
        std.debug.print("div children: {}\n", .{ch.len()});
    }

    std.debug.print("\n--- find html ---\n", .{});
    var doc3 = try zq.Document.initFromSlice(alloc, "<!DOCTYPE html><html lang=\"en\"><body><p>X</p></body></html>");
    const htmls = try doc3.find("html");
    std.debug.print("html elements: {}\n", .{htmls.len()});
    if (htmls.len() > 0) {
        std.debug.print("html lang: {s}\n", .{htmls.attr("lang") orelse "null"});
    }
}

fn printTree(node: *const zq.Node, depth: usize) void {
    for (0..depth) |_| std.debug.print("  ", .{});
    switch (node.node_type) {
        .element => std.debug.print("<{s}>\n", .{node.data}),
        .text => std.debug.print("TEXT: '{s}'\n", .{node.data[0..@min(node.data.len, 40)]}),
        .document => std.debug.print("[document]\n", .{}),
        .comment => std.debug.print("<!-- -->\n", .{}),
        .doctype => std.debug.print("<!DOCTYPE {s}>\n", .{node.data}),
    }
    var child = node.first_child;
    while (child) |c| {
        printTree(c, depth + 1);
        child = c.next_sibling;
    }
}
