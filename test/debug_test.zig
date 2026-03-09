const std = @import("std");
const zq = @import("zigquery");

test "debug tree structure" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<div><p>Hello</p><p>World</p></div>");
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
        for (ch.nodes) |n| {
            std.debug.print("  child: {s} type={}\n", .{ n.data, @intFromEnum(n.node_type) });
        }
    }

    std.debug.print("\n--- html() test ---\n", .{});
    var doc2 = try zq.Document.initFromSlice(std.testing.allocator, "<div><p>test</p></div>");
    defer doc2.deinit();
    const d2 = try doc2.find("div");
    std.debug.print("div count: {}\n", .{d2.len()});
    if (d2.len() > 0) {
        const h = try d2.html();
        std.debug.print("html: '{s}'\n", .{h});
    }

    std.debug.print("\n--- find html element ---\n", .{});
    var doc3 = try zq.Document.initFromSlice(std.testing.allocator, "<!DOCTYPE html><html lang=\"en\"><body><p>X</p></body></html>");
    defer doc3.deinit();
    printTree(doc3.root_node, 0);
    const htmls = try doc3.find("html");
    std.debug.print("html elements: {}\n", .{htmls.len()});
}

fn printTree(node: *const zq.Node, depth: usize) void {
    for (0..depth) |_| std.debug.print("  ", .{});
    switch (node.node_type) {
        .element => std.debug.print("<{s}>\n", .{node.data}),
        .text => {
            const data = node.data[0..@min(node.data.len, 40)];
            std.debug.print("TEXT: '{s}'\n", .{data});
        },
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
