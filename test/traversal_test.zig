const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

test "find descendants" {
    var doc = try helper.parseDoc("<div><p><span>A</span></p><p><span>B</span></p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const spans = try div.find("span");
    try std.testing.expect(spans.len() == 2);
}

test "children" {
    var doc = try helper.parseDoc("<div><p>A</p><p>B</p><span>C</span></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const ch = div.children();
    try std.testing.expect(ch.len() == 3);
}

test "childrenFiltered" {
    var doc = try helper.parseDoc("<div><p>A</p><span>B</span><p>C</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const ps = try div.childrenFiltered("p");
    try std.testing.expect(ps.len() == 2);
}

test "parent" {
    var doc = try helper.parseDoc("<div><p>A</p></div>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    const par = p_sel.parent();
    try std.testing.expect(par.len() == 1);
    try std.testing.expectEqualStrings("div", par.nodes[0].data);
}

test "parents" {
    var doc = try helper.parseDoc("<div><ul><li>A</li></ul></div>");
    defer doc.deinit();
    const li = try doc.find("li");
    const anc = li.parents();
    // ancestors: ul, div, body, html
    try std.testing.expect(anc.len() >= 2);
}

test "siblings" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();

    const n3 = try doc.find("#n3");
    try std.testing.expect(n3.len() == 1);

    const sibs = n3.siblings();
    // #main has 6 children, siblings of #n3 = 5
    try std.testing.expect(sibs.len() == 5);
}

test "next sibling" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();
    const n2 = try doc.find("#n2");
    const nxt = n2.next();
    try std.testing.expect(nxt.len() == 1);
    try std.testing.expectEqualStrings("n3", nxt.attr("id").?);
}

test "prev sibling" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();
    const n3 = try doc.find("#n3");
    const prv = n3.prev();
    try std.testing.expect(prv.len() == 1);
    try std.testing.expectEqualStrings("n2", prv.attr("id").?);
}

test "nextAll" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();
    const n2 = try doc.find("#n2");
    const nxt = n2.nextAll();
    // n3, n4, n5, n6
    try std.testing.expect(nxt.len() == 4);
}

test "prevAll" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();
    const n5 = try doc.find("#n5");
    const prv = n5.prevAll();
    // n1, n2, n3, n4
    try std.testing.expect(prv.len() == 4);
}

test "closest" {
    var doc = try helper.parseDoc("<div class=\"outer\"><div class=\"inner\"><p>test</p></div></div>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    const c = try p_sel.closest("div");
    try std.testing.expect(c.len() == 1);
    try std.testing.expect(c.hasClass("inner"));
}

test "contents includes text nodes" {
    var doc = try helper.parseDoc("<div>text<span>child</span></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const c = div.contents();
    // At least a text node and a span.
    try std.testing.expect(c.len() >= 2);
}

test "find on page.html" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page_html);
    defer doc.deinit();

    // page.html has container-fluid divs.
    const cf = try doc.find(".container-fluid");
    try std.testing.expect(cf.len() > 0);

    // Has links with class "link".
    const links = try doc.find("a.link");
    try std.testing.expect(links.len() > 0);
}
