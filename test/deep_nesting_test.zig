//! Deeply nested input.
//!
//! `appendChild` asserts on `wouldCreateCycle`, and an assert's argument is
//! evaluated in every build mode -- so an O(depth) ancestor walk there turns
//! tree building into O(nodes * depth). At 50 000 levels that was about ten
//! seconds; these tests fail by timing out in CI if it ever comes back.

const std = @import("std");
const zq = @import("zigquery");

const depth = 50_000;

fn nestedHtml(gpa: std.mem.Allocator, levels: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "<html><body>");
    for (0..levels) |_| try buf.appendSlice(gpa, "<div class=\"n\">");
    try buf.appendSlice(gpa, "<a class=\"link\" href=\"/deep\">bottom</a>");
    for (0..levels) |_| try buf.appendSlice(gpa, "</div>");
    try buf.appendSlice(gpa, "</body></html>");
    return buf.toOwnedSlice(gpa);
}

test "parses 50k nested elements" {
    const gpa = std.testing.allocator;
    const html = try nestedHtml(gpa, depth);
    defer gpa.free(html);

    var doc = try zq.Document.initFromSlice(gpa, html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    // Walk to the deepest element and confirm the tree really is that deep,
    // rather than having been silently flattened.
    var node = doc.root_node;
    var measured: usize = 0;
    while (node.first_child) |child| : (node = child) measured += 1;
    try std.testing.expect(measured >= depth);
}

test "queries a 50k deep document" {
    const gpa = std.testing.allocator;
    const html = try nestedHtml(gpa, depth);
    defer gpa.free(html);

    var doc = try zq.Document.initFromSlice(gpa, html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    const links = try q.find("a.link");
    try std.testing.expectEqual(@as(usize, 1), links.len());

    const divs = try q.find("div.n");
    try std.testing.expectEqual(@as(usize, depth), divs.len());
}

test "renders and clones a 50k deep document" {
    const gpa = std.testing.allocator;
    const html = try nestedHtml(gpa, depth);
    defer gpa.free(html);

    var doc = try zq.Document.initFromSlice(gpa, html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    const rendered = try zq.html_render.renderToString(gpa, doc.root_node);
    defer gpa.free(rendered);
    try std.testing.expectEqual(@as(usize, depth), std.mem.count(u8, rendered, "</div>"));

    var copy = try doc.clone(gpa);
    defer copy.deinit();
    var q_copy = copy.query(std.testing.allocator);
    defer q_copy.deinit();
    const copied = try q_copy.find("a.link");
    try std.testing.expectEqual(@as(usize, 1), copied.len());
}

test "extracts text from a 50k deep document" {
    const gpa = std.testing.allocator;
    const html = try nestedHtml(gpa, depth);
    defer gpa.free(html);

    var doc = try zq.Document.initFromSlice(gpa, html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    const body = try q.find("body");
    const text = try body.text();
    try std.testing.expectEqualStrings("bottom", text);
}

test "cycle detection still rejects a real cycle" {
    // The `wouldCreateCycle` short-circuit keys off `child.first_child`, so
    // the case that matters is a child that *does* have descendants and is an
    // ancestor of the proposed parent.
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, "<div id=\"outer\"><div id=\"inner\"><p>x</p></div></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    const outer = (try q.find("#outer")).nodes[0];
    const inner = (try q.find("#inner")).nodes[0];

    // Re-parenting an ancestor under its own descendant is a cycle.
    try std.testing.expectError(error.Cycle, zq.tree.appendChildChecked(inner, outer));
    try std.testing.expectError(error.Cycle, zq.tree.insertBeforeChecked(inner, outer, null));

    // A node cannot be appended to itself.
    try std.testing.expectError(error.Cycle, zq.tree.appendChildChecked(outer, outer));

    // The legitimate direction still works, and leaves a valid tree.
    const para = (try q.find("p")).nodes[0];
    try zq.tree.appendChildChecked(outer, para);
    try zq.tree.validate(gpa, doc.root_node);
}

test "cycle detection rejects a childless node appended to itself" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, "<div id=\"a\"></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    const a = (try q.find("#a")).nodes[0];
    try std.testing.expect(a.first_child == null);
    try std.testing.expectError(error.Cycle, zq.tree.appendChildChecked(a, a));
}
