const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

test "Document.initFromSlice" {
    var doc = try helper.parseDoc("<html><body><div>test</div></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.root_node.node_type == .document);
}

test "Document.find" {
    var doc = try helper.parseDoc("<div><p>Hello</p><p>World</p></div>");
    defer doc.deinit();
    const sel = try doc.find("p");
    try std.testing.expect(sel.len() == 2);
}

test "Document.clone" {
    var doc = try helper.parseDoc("<div><p>test</p></div>");
    defer doc.deinit();
    var cloned = try doc.clone(std.testing.allocator);
    defer cloned.deinit();
    const sel = try cloned.find("p");
    try std.testing.expect(sel.len() == 1);
}

test "Document from page.html" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page_html);
    defer doc.deinit();

    // page.html has multiple divs.
    const divs = try doc.find("div");
    try std.testing.expect(divs.len() > 0);

    // Has links.
    const links = try doc.find("a");
    try std.testing.expect(links.len() > 0);
}

test "Document from page2.html" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();

    // page2.html has div#main with 6 child divs.
    const main_div = try doc.find("#main");
    try std.testing.expect(main_div.len() == 1);

    const children = main_div.children();
    try std.testing.expect(children.len() == 6);
}

test "Document from page3.html" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page3_html);
    defer doc.deinit();

    const main_div = try doc.find("#main");
    try std.testing.expect(main_div.len() == 1);
}

test "empty document" {
    var doc = try helper.parseDoc("");
    defer doc.deinit();
    const sel = try doc.find("div");
    try std.testing.expect(sel.len() == 0);
}
