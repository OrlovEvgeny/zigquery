const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

test "Document.initFromSlice" {
    var doc = try helper.parseDoc("<html><body><div>test</div></body></html>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    try std.testing.expect(doc.root_node.node_type == .document);
}

test "Document.find" {
    var doc = try helper.parseDoc("<div><p>Hello</p><p>World</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const sel = try q.find("p");
    try std.testing.expect(sel.len() == 2);
}

test "Document.clone" {
    var doc = try helper.parseDoc("<div><p>test</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    var cloned = try doc.clone(std.testing.allocator);
    defer cloned.deinit();
    var q_cloned = cloned.query(std.testing.allocator);
    defer q_cloned.deinit();
    const sel = try q_cloned.find("p");
    try std.testing.expect(sel.len() == 1);
}

test "Document owns input and clone strings" {
    const input = try std.testing.allocator.dupe(u8, "<div data-value=\"original\">text</div>");
    var doc = try zq.Document.initFromSlice(std.testing.allocator, input);
    std.testing.allocator.free(input);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    var cloned = try doc.clone(std.testing.allocator);
    defer cloned.deinit();
    var q_cloned = cloned.query(std.testing.allocator);
    defer q_cloned.deinit();

    const div = try q_cloned.find("div");
    try std.testing.expectEqualStrings("original", div.attr("data-value").?);
    try std.testing.expectEqualStrings("text", try div.text());
}

test "Document.initFromNode creates an owning clone" {
    var source = zq.Node{ .node_type = .element, .data = "div" };
    var doc = try zq.Document.initFromNode(std.testing.allocator, &source);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    try std.testing.expect(doc.root_node != &source);
    try std.testing.expectEqualStrings("div", doc.root_node.data);
}

test "Document from page.html" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    // page.html has multiple divs.
    const divs = try q.find("div");
    try std.testing.expect(divs.len() > 0);

    // Has links.
    const links = try q.find("a");
    try std.testing.expect(links.len() > 0);
}

test "Document from page2.html" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    // page2.html has div#main with 6 child divs.
    const main_div = try q.find("#main");
    try std.testing.expect(main_div.len() == 1);

    const children = try main_div.children();
    try std.testing.expect(children.len() == 6);
}

test "Document from page3.html" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page3_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    const main_div = try q.find("#main");
    try std.testing.expect(main_div.len() == 1);
}

test "empty document" {
    var doc = try helper.parseDoc("");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const sel = try q.find("div");
    try std.testing.expect(sel.len() == 0);
}
