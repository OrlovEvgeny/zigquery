const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

test "attr" {
    var doc = try helper.parseDoc("<a href=\"/test\" id=\"link1\">click</a>");
    defer doc.deinit();
    const a = try doc.find("a");
    try std.testing.expectEqualStrings("/test", a.attr("href").?);
    try std.testing.expectEqualStrings("link1", a.attr("id").?);
    try std.testing.expect(a.attr("class") == null);
}

test "attrOr" {
    var doc = try helper.parseDoc("<div>test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expectEqualStrings("default", div.attrOr("class", "default"));
}

test "setAttr" {
    var doc = try helper.parseDoc("<div id=\"original\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.setAttr("id", "modified");
    try std.testing.expectEqualStrings("modified", div.attr("id").?);
}

test "setAttr new attribute" {
    var doc = try helper.parseDoc("<div>test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.setAttr("data-x", "value");
    try std.testing.expectEqualStrings("value", div.attr("data-x").?);
}

test "removeAttr" {
    var doc = try helper.parseDoc("<div id=\"main\" class=\"foo\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.removeAttr("class");
    try std.testing.expect(div.attr("class") == null);
    try std.testing.expect(div.attr("id") != null);
}

test "hasClass" {
    var doc = try helper.parseDoc("<div class=\"foo bar baz\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expect(div.hasClass("foo"));
    try std.testing.expect(div.hasClass("bar"));
    try std.testing.expect(div.hasClass("baz"));
    try std.testing.expect(!div.hasClass("qux"));
}

test "addClass" {
    var doc = try helper.parseDoc("<div class=\"foo\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.addClass("bar");
    try std.testing.expect(div.hasClass("foo"));
    try std.testing.expect(div.hasClass("bar"));
}

test "addClass does not duplicate" {
    var doc = try helper.parseDoc("<div class=\"foo\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.addClass("foo");
    const class_val = div.attr("class").?;
    // Should not have "foo" twice.
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, class_val, ' ');
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, "foo")) count += 1;
    }
    try std.testing.expect(count == 1);
}

test "removeClass" {
    var doc = try helper.parseDoc("<div class=\"foo bar baz\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.removeClass("bar");
    try std.testing.expect(div.hasClass("foo"));
    try std.testing.expect(!div.hasClass("bar"));
    try std.testing.expect(div.hasClass("baz"));
}

test "removeClass all" {
    var doc = try helper.parseDoc("<div class=\"foo bar\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.removeClass("");
    try std.testing.expect(div.attr("class") == null);
}

test "toggleClass" {
    var doc = try helper.parseDoc("<div class=\"foo\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.toggleClass("foo");
    try std.testing.expect(!div.hasClass("foo"));
    div.toggleClass("foo");
    try std.testing.expect(div.hasClass("foo"));
}

test "text" {
    var doc = try helper.parseDoc("<div>Hello <span>World</span></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const t = try div.text();
    try std.testing.expect(std.mem.indexOf(u8, t, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "World") != null);
}

test "html" {
    var doc = try helper.parseDoc("<div><p>test</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const h = try div.html();
    try std.testing.expect(std.mem.indexOf(u8, h, "<p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "test") != null);
}

test "page.html attr access" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page_html);
    defer doc.deinit();
    const html_el = try doc.find("html");
    try std.testing.expect(html_el.len() == 1);
    try std.testing.expectEqualStrings("en", html_el.attr("lang").?);
}
