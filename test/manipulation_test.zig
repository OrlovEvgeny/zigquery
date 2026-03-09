const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

test "remove" {
    var doc = try helper.parseDoc("<div><p>keep</p><span>remove</span></div>");
    defer doc.deinit();
    const span = try doc.find("span");
    _ = span.remove();
    const remaining = try doc.find("span");
    try std.testing.expect(remaining.len() == 0);
    const p_sel = try doc.find("p");
    try std.testing.expect(p_sel.len() == 1);
}

test "empty" {
    var doc = try helper.parseDoc("<div><p>A</p><p>B</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const removed = div.empty();
    try std.testing.expect(removed.len() == 2); // two p nodes removed
    // div should now be empty.
    try std.testing.expect(div.children().len() == 0);
}

test "appendHtml" {
    var doc = try helper.parseDoc("<div><p>existing</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.appendHtml("<span>new</span>");
    const span = try doc.find("span");
    try std.testing.expect(span.len() == 1);
    const t = try span.text();
    try std.testing.expectEqualStrings("new", t);
}

test "prependHtml" {
    var doc = try helper.parseDoc("<div><p>existing</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.prependHtml("<span>first</span>");
    const children = div.children();
    try std.testing.expect(children.len() == 2);
    // First child should be the span.
    try std.testing.expectEqualStrings("span", children.nodes[0].data);
}

test "afterHtml" {
    var doc = try helper.parseDoc("<div><p>A</p></div>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    p_sel.afterHtml("<span>B</span>");
    const div = try doc.find("div");
    const children = div.children();
    try std.testing.expect(children.len() == 2);
}

test "beforeHtml" {
    var doc = try helper.parseDoc("<div><p>A</p></div>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    p_sel.beforeHtml("<span>B</span>");
    const div = try doc.find("div");
    const children = div.children();
    try std.testing.expect(children.len() == 2);
    try std.testing.expectEqualStrings("span", children.nodes[0].data);
}

test "replaceWithHtml" {
    var doc = try helper.parseDoc("<div><p>old</p></div>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    _ = p_sel.replaceWithHtml("<span>new</span>");
    const new_span = try doc.find("span");
    try std.testing.expect(new_span.len() == 1);
    const old_p = try doc.find("p");
    try std.testing.expect(old_p.len() == 0);
}

test "setHtml" {
    var doc = try helper.parseDoc("<div><p>old</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.setHtml("<span>new content</span>");
    const span = try doc.find("span");
    try std.testing.expect(span.len() == 1);
    const p_sel = try doc.find("p");
    try std.testing.expect(p_sel.len() == 0);
}

test "setText" {
    var doc = try helper.parseDoc("<div><p>old</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    div.setText("plain text <escaped>");
    const t = try div.text();
    try std.testing.expect(std.mem.indexOf(u8, t, "plain text") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "<escaped>") != null);
}

test "cloneSel" {
    var doc = try helper.parseDoc("<div><p>test</p></div>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    const cloned = p_sel.cloneSel();
    try std.testing.expect(cloned.len() == 1);
    // Cloned node is a different pointer.
    try std.testing.expect(cloned.nodes[0] != p_sel.nodes[0]);
    const t = try cloned.text();
    try std.testing.expectEqualStrings("test", t);
}

test "unwrap" {
    var doc = try helper.parseDoc("<div><span><p>content</p></span></div>");
    defer doc.deinit();
    const p_sel = try doc.find("p");
    p_sel.unwrap();
    // The span wrapper should be gone.
    const span = try doc.find("span");
    try std.testing.expect(span.len() == 0);
    // The p should still be there under div.
    const p_after = try doc.find("p");
    try std.testing.expect(p_after.len() == 1);
}

test "outerHtml" {
    var doc = try helper.parseDoc("<div id=\"x\"><p>test</p></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const oh = try zq.outerHtml(div);
    try std.testing.expect(std.mem.indexOf(u8, oh, "<div") != null);
    try std.testing.expect(std.mem.indexOf(u8, oh, "</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, oh, "<p>test</p>") != null);
}

test "nodeName" {
    var doc = try helper.parseDoc("<div>test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expectEqualStrings("div", zq.nodeName(div));
}
