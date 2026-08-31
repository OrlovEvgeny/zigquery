const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

fn setHtmlWithFailures(allocator: std.mem.Allocator) !void {
    var doc = try zq.Document.initFromSlice(allocator, "<main><div><p>A</p></div><div><p>B</p></div></main>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const divs = try q.find("div");
    const first_children = [_]?*zq.Node{ divs.nodes[0].first_child, divs.nodes[1].first_child };

    divs.setHtml("<section><span>updated</span></section>") catch |err| {
        try std.testing.expect(divs.nodes[0].first_child == first_children[0]);
        try std.testing.expect(divs.nodes[1].first_child == first_children[1]);
        return err;
    };

    try std.testing.expectEqualStrings("section", divs.nodes[0].first_child.?.data);
    try std.testing.expectEqualStrings("section", divs.nodes[1].first_child.?.data);
}

test "remove" {
    var doc = try helper.parseDoc("<div><p>keep</p><span>remove</span></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const span = try q.find("span");
    _ = span.remove();
    const remaining = try q.find("span");
    try std.testing.expect(remaining.len() == 0);
    const p_sel = try q.find("p");
    try std.testing.expect(p_sel.len() == 1);
}

test "empty" {
    var doc = try helper.parseDoc("<div><p>A</p><p>B</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    const removed = try div.empty();
    try std.testing.expect(removed.len() == 2); // two p nodes removed
    // div should now be empty.
    try std.testing.expect((try div.children()).len() == 0);
}

test "appendHtml" {
    var doc = try helper.parseDoc("<div><p>existing</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    try div.appendHtml("<span>new</span>");
    const span = try q.find("span");
    try std.testing.expect(span.len() == 1);
    const t = try span.text();
    try std.testing.expectEqualStrings("new", t);
}

test "prependHtml" {
    var doc = try helper.parseDoc("<div><p>existing</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    try div.prependHtml("<span>first</span>");
    const children = try div.children();
    try std.testing.expect(children.len() == 2);
    // First child should be the span.
    try std.testing.expectEqualStrings("span", children.nodes[0].data);
}

test "prependHtml preserves source order" {
    var doc = try helper.parseDoc("<div><i>existing</i></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    try div.prependHtml("<span>A</span><b>B</b>");
    const children = try div.children();
    try std.testing.expectEqualStrings("span", children.nodes[0].data);
    try std.testing.expectEqualStrings("b", children.nodes[1].data);
    try std.testing.expectEqualStrings("i", children.nodes[2].data);
}

test "afterHtml" {
    var doc = try helper.parseDoc("<div><p>A</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const p_sel = try q.find("p");
    try p_sel.afterHtml("<span>B</span>");
    const div = try q.find("div");
    const children = try div.children();
    try std.testing.expect(children.len() == 2);
}

test "beforeHtml" {
    var doc = try helper.parseDoc("<div><p>A</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const p_sel = try q.find("p");
    try p_sel.beforeHtml("<span>B</span>");
    const div = try q.find("div");
    const children = try div.children();
    try std.testing.expect(children.len() == 2);
    try std.testing.expectEqualStrings("span", children.nodes[0].data);
}

test "replaceWithHtml" {
    var doc = try helper.parseDoc("<div><p>old</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const p_sel = try q.find("p");
    _ = try p_sel.replaceWithHtml("<span>new</span>");
    const new_span = try q.find("span");
    try std.testing.expect(new_span.len() == 1);
    const old_p = try q.find("p");
    try std.testing.expect(old_p.len() == 0);
}

test "setHtml" {
    var doc = try helper.parseDoc("<div><p>old</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    try div.setHtml("<span>new content</span>");
    const span = try q.find("span");
    try std.testing.expect(span.len() == 1);
    const p_sel = try q.find("p");
    try std.testing.expect(p_sel.len() == 0);
}

test "setHtml is atomic on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, setHtmlWithFailures, .{});
}

test "setText" {
    var doc = try helper.parseDoc("<div><p>old</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    try div.setText("plain text <escaped>");
    const t = try div.text();
    try std.testing.expect(std.mem.indexOf(u8, t, "plain text") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "<escaped>") != null);
}

test "cloneSel" {
    var doc = try helper.parseDoc("<div><p>test</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const p_sel = try q.find("p");
    const cloned = try p_sel.cloneSel();
    try std.testing.expect(cloned.len() == 1);
    // Cloned node is a different pointer.
    try std.testing.expect(cloned.nodes[0] != p_sel.nodes[0]);
    const t = try cloned.text();
    try std.testing.expectEqualStrings("test", t);
}

test "unwrap" {
    var doc = try helper.parseDoc("<div><span><p>content</p></span></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const p_sel = try q.find("p");
    try p_sel.unwrap();
    // The span wrapper should be gone.
    const span = try q.find("span");
    try std.testing.expect(span.len() == 0);
    // The p should still be there under div.
    const p_after = try q.find("p");
    try std.testing.expect(p_after.len() == 1);
}

test "outerHtml" {
    var doc = try helper.parseDoc("<div id=\"x\"><p>test</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    const oh = try zq.outerHtml(div);
    try std.testing.expect(std.mem.indexOf(u8, oh, "<div") != null);
    try std.testing.expect(std.mem.indexOf(u8, oh, "</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, oh, "<p>test</p>") != null);
}

test "nodeName" {
    var doc = try helper.parseDoc("<div>test</div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    try std.testing.expectEqualStrings("div", zq.nodeName(div));
}

test "node insertion clones source for every destination" {
    var target = try helper.parseDoc("<main><div></div><div></div></main>");
    defer target.deinit();
    var q_target = target.query(std.testing.allocator);
    defer q_target.deinit();

    {
        var source = try helper.parseDoc("<aside><em data-x=value>owned text</em></aside>");
        defer source.deinit();
        var q_source = source.query(std.testing.allocator);
        defer q_source.deinit();

        const destinations = try q_target.find("div");
        const source_nodes = try q_source.find("em");
        const source_parent = source_nodes.nodes[0].parent;
        try destinations.appendNodes(source_nodes.nodes);

        try std.testing.expect(source_nodes.nodes[0].parent == source_parent);
    }

    const inserted = try q_target.find("em");
    try std.testing.expectEqual(@as(usize, 2), inserted.len());
    try std.testing.expect(inserted.nodes[0] != inserted.nodes[1]);
    try std.testing.expectEqualStrings("value", inserted.attr("data-x").?);
    try std.testing.expectEqualStrings("owned textowned text", try inserted.text());
    try zq.tree.validate(std.testing.allocator, target.root_node);
}

test "wrap operations preserve tree invariants" {
    var doc = try helper.parseDoc("<main><p>A</p><p>B</p></main>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    const paragraphs = try q.find("p");
    try paragraphs.wrapHtml("<section><article></article></section>");
    try std.testing.expect((try q.find("section > article > p")).len() == 2);
    try zq.tree.validate(std.testing.allocator, doc.root_node);
}

test "wrap rejects non-element containers" {
    var doc = try helper.parseDoc("<main><p>A</p></main>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const paragraph = try q.find("p");

    var text = zq.Node{ .node_type = .text, .data = "not a wrapper" };
    try std.testing.expectError(error.InvalidWrapper, paragraph.wrapNode(&text));
    try std.testing.expectError(error.InvalidWrapper, paragraph.wrapHtml("text only"));
    try zq.tree.validate(std.testing.allocator, doc.root_node);
}
