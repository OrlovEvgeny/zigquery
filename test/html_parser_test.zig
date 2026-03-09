const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

test "parse page.html without crashing" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page_html);
    defer doc.deinit();
    try std.testing.expect(doc.root_node.node_type == .document);
}

test "parse page2.html without crashing" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();
    try std.testing.expect(doc.root_node.node_type == .document);
}

test "parse page3.html without crashing" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page3_html);
    defer doc.deinit();
    try std.testing.expect(doc.root_node.node_type == .document);
}

test "parse basic structure" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<html><head><title>Test</title></head><body><p>Hello</p></body></html>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    try std.testing.expect(p_sel.len() == 1);
    const t = try p_sel.text();
    try std.testing.expectEqualStrings("Hello", t);
}

test "parse void elements" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<div><br><hr><img src=\"test.png\"></div>");
    defer doc.deinit();
    const br = try doc.find("br");
    try std.testing.expect(br.len() == 1);
    const hr = try doc.find("hr");
    try std.testing.expect(hr.len() == 1);
    const img = try doc.find("img");
    try std.testing.expect(img.len() == 1);
    try std.testing.expectEqualStrings("test.png", img.attr("src").?);
}

test "parse with doctype" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<!DOCTYPE html><html><body><div>content</div></body></html>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expect(div.len() == 1);
}

test "parse nested elements" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<div><ul><li>1</li><li>2</li><li>3</li></ul></div>");
    defer doc.deinit();
    const li = try doc.find("li");
    try std.testing.expect(li.len() == 3);
}

test "parse comments" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<div><!-- comment --><p>text</p></div>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    try std.testing.expect(p_sel.len() == 1);
}

test "parse raw text elements" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<script>var x = 1 < 2;</script><p>ok</p>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    try std.testing.expect(p_sel.len() == 1);
}

test "case-insensitive tags" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<DIV><P>Hello</P></DIV>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expect(div.len() == 1);
    const p_sel = try doc.find("p");
    try std.testing.expect(p_sel.len() == 1);
}
