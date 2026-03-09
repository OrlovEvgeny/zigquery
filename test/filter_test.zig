const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

test "filter by selector" {
    var doc = try helper.parseDoc("<div><p class=\"a\">1</p><p class=\"b\">2</p><p class=\"a\">3</p></div>");
    defer doc.deinit();
    const ps = try doc.find("p");
    try std.testing.expect(ps.len() == 3);
    const filtered = try ps.filter(".a");
    try std.testing.expect(filtered.len() == 2);
}

test "not by selector" {
    var doc = try helper.parseDoc("<div><p class=\"a\">1</p><p class=\"b\">2</p><p class=\"a\">3</p></div>");
    defer doc.deinit();
    const ps = try doc.find("p");
    const not_a = try ps.not(".a");
    try std.testing.expect(not_a.len() == 1);
}

test "has" {
    var doc = try helper.parseDoc("<div><p><span>yes</span></p></div><div><p>no span</p></div>");
    defer doc.deinit();
    const divs = try doc.find("div");
    const with_span = try divs.has("span");
    try std.testing.expect(with_span.len() == 1);
}

test "is" {
    var doc = try helper.parseDoc("<div class=\"active\"><p>test</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expect(div.is(".active"));
    try std.testing.expect(!div.is(".inactive"));
}

test "filter on page2.html" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, helper.page2_html);
    defer doc.deinit();

    const rows = try doc.find(".row");
    try std.testing.expect(rows.len() > 0);

    const odd = try rows.filter(".odd");
    const even = try rows.filter(".even");
    try std.testing.expect(odd.len() > 0);
    try std.testing.expect(even.len() > 0);
    try std.testing.expect(odd.len() + even.len() == rows.len());
}

test "intersection" {
    var doc = try helper.parseDoc("<div><p class=\"a\">1</p><p class=\"b\">2</p></div>");
    defer doc.deinit();
    const ps = try doc.find("p");
    const a = try doc.find(".a");
    const inter = ps.intersection(a);
    try std.testing.expect(inter.len() == 1);
}

test "end returns previous" {
    var doc = try helper.parseDoc("<div><p>A</p><span>B</span></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const children = div.children();
    const filtered = try children.filter("p");
    try std.testing.expect(filtered.len() == 1);
    const back = filtered.end();
    try std.testing.expect(back.len() == 2); // back to children
}
