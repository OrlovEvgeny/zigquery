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

test "numeric entities decode and render without double escaping" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<p>&#65; &#x1F600;</p>");
    defer doc.deinit();

    const paragraph = try doc.find("p");
    try std.testing.expectEqualStrings("A \xf0\x9f\x98\x80", try paragraph.text());
    try std.testing.expectEqualStrings("<p>A \xf0\x9f\x98\x80</p>", try zq.outerHtml(paragraph));
}

test "implicit head and leading whitespace produce valid structure" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "\n<!doctype html>\n<html>\n<title>T &amp; C</title><body><p>x</p></body></html>");
    defer doc.deinit();

    const html = try doc.find("html");
    const head = try html.childrenFiltered("head");
    const body = try html.childrenFiltered("body");
    try std.testing.expect(head.len() == 1);
    try std.testing.expect(body.len() == 1);
    try std.testing.expectEqualStrings("T & C", try (try head.find("title")).text());
}

test "table cells auto close" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<table><tr><td>A<td>B</tr></table>");
    defer doc.deinit();

    const cells = try doc.find("td");
    try std.testing.expect(cells.len() == 2);
    try std.testing.expect(cells.nodes[0].parent == cells.nodes[1].parent);
}

test "explicit head and body retain later content" {
    var doc = try zq.Document.initFromSlice(
        std.testing.allocator,
        "<html><head></head><meta name=x><body><p>first</p></body><p>second</p></html>",
    );
    defer doc.deinit();

    try std.testing.expect((try doc.find("head > meta")).len() == 1);
    try std.testing.expect((try doc.find("body > p")).len() == 2);
}

test "duplicate attributes keep the first value" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<div ID=first id=second></div>");
    defer doc.deinit();

    const div = try doc.find("div");
    try std.testing.expectEqualStrings("first", div.attr("id").?);
    try std.testing.expectEqual(@as(usize, 1), div.nodes[0].attr.len);
}

test "unquoted attribute value keeps slashes" {
    var doc = try zq.Document.initFromSlice(
        std.testing.allocator,
        "<a href=books/learning-zig/chapter11/ class=link>Chapter 11</a>",
    );
    defer doc.deinit();

    const a = try doc.find("a");
    try std.testing.expectEqual(@as(usize, 1), a.len());
    try std.testing.expectEqualStrings("books/learning-zig/chapter11/", a.attr("href").?);
    try std.testing.expectEqualStrings("link", a.attr("class").?);

    const t = try a.text();
    try std.testing.expectEqualStrings("Chapter 11", t);
}

test "unquoted attributes across a minified document" {
    const html =
        "<!DOCTYPE html>" ++
        "<html lang=en>" ++
        "<head><meta charset=UTF-8>" ++
        "<meta name=viewport content=\"width=device-width, initial-scale=1.0\">" ++
        "<title>Document</title></head>" ++
        "<body><a href=books/learning-zig/chapter11/ class=link>Chapter 11</a></body>" ++
        "</html>";

    var doc = try zq.Document.initFromSlice(std.testing.allocator, html);
    defer doc.deinit();

    try std.testing.expectEqualStrings("en", (try doc.find("html")).attr("lang").?);
    try std.testing.expectEqualStrings("UTF-8", (try doc.find("meta[charset]")).attr("charset").?);
    try std.testing.expectEqualStrings(
        "width=device-width, initial-scale=1.0",
        (try doc.find("meta[name=viewport]")).attr("content").?,
    );
    try std.testing.expectEqualStrings("Document", try (try doc.find("title")).text());

    const links = try doc.find("a.link");
    try std.testing.expectEqual(@as(usize, 1), links.len());
    try std.testing.expectEqualStrings("books/learning-zig/chapter11/", links.attr("href").?);
}

test "unquoted attribute followed by self closing slash" {
    var doc = try zq.Document.initFromSlice(
        std.testing.allocator,
        "<div><img src=a/b.png /><img src=c.png></div>",
    );
    defer doc.deinit();

    const imgs = try doc.find("img");
    try std.testing.expectEqual(@as(usize, 2), imgs.len());
    try std.testing.expectEqualStrings("a/b.png", imgs.nodes[0].getAttr("src").?);
    try std.testing.expectEqualStrings("c.png", imgs.nodes[1].getAttr("src").?);
}

test "trailing slash without gap belongs to unquoted value" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<a href=/docs/>text</a>");
    defer doc.deinit();

    const a = try doc.find("a");
    try std.testing.expectEqual(@as(usize, 1), a.len());
    try std.testing.expectEqualStrings("/docs/", a.attr("href").?);
    try std.testing.expectEqualStrings("text", try a.text());
}

test "stray slash between attributes does not drop them" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<div id=a / class=b></div>");
    defer doc.deinit();

    const div = try doc.find("div");
    try std.testing.expectEqual(@as(usize, 1), div.len());
    try std.testing.expectEqualStrings("a", div.attr("id").?);
    try std.testing.expectEqualStrings("b", div.attr("class").?);
}

test "void element self closes with unquoted attribute" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<p>a<br/>b</p>");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), (try doc.find("br")).len());
    try std.testing.expectEqual(@as(usize, 1), (try doc.find("p")).len());
}

test "unquoted value decodes entities" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<a href=/a&amp;b/c>x</a>");
    defer doc.deinit();

    try std.testing.expectEqualStrings("/a&b/c", (try doc.find("a")).attr("href").?);
}
