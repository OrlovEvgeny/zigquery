//! Positional pseudo-classes.
//!
//! These are answered by looking at neighbouring siblings rather than by
//! counting the whole sibling list, so the cases that matter are the ones
//! where non-element nodes sit between elements and where the position is
//! counted from the far end.

const std = @import("std");
const zq = @import("zigquery");

// Element positions inside <ul>: l1=1, l2=2, s1=3, l3=4.
// The newlines between tags become text nodes, which must not be counted.
const list_html =
    \\<ul>
    \\  <li id="l1">one</li>
    \\  <li id="l2">two</li>
    \\  <span id="s1">x</span>
    \\  <li id="l3">three</li>
    \\</ul>
;

fn idsOf(sel: zq.Selection, buf: [][]const u8) [][]const u8 {
    for (sel.nodes, 0..) |n, i| buf[i] = n.getAttr("id") orelse "";
    return buf[0..sel.nodes.len];
}

fn expectIds(sel: zq.Selection, expected: []const []const u8) !void {
    var buf: [16][]const u8 = undefined;
    const got = idsOf(sel, &buf);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try std.testing.expectEqualStrings(want, have);
}

test ":first-child, :last-child, :only-child" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, list_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    try expectIds(try q.find("li:first-child"), &.{"l1"});
    try expectIds(try q.find("li:last-child"), &.{"l3"});
    try expectIds(try q.find("span:first-child"), &.{});
    try expectIds(try q.find("li:only-child"), &.{});
}

test ":only-child matches a lone element" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator,
        \\<div><p id="solo">only</p></div><div><p id="a">a</p><p id="b">b</p></div>
    );
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    try expectIds(try q.find("p:only-child"), &.{"solo"});
}

test ":first-of-type, :last-of-type, :only-of-type" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, list_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    try expectIds(try q.find("li:first-of-type"), &.{"l1"});
    try expectIds(try q.find("li:last-of-type"), &.{"l3"});
    try expectIds(try q.find("span:only-of-type"), &.{"s1"});
    try expectIds(try q.find("li:only-of-type"), &.{});
}

test ":nth-child with a literal position" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, list_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    // Scoped to the list: an unscoped `:nth-child(1)` also matches <head>,
    // <ul> and every other first child in the implied document structure.
    try expectIds(try q.find("ul > :nth-child(1)"), &.{"l1"});
    try expectIds(try q.find("ul > :nth-child(2)"), &.{"l2"});
    // Position 3 is the span: the intervening text nodes are not counted.
    try expectIds(try q.find("ul > :nth-child(3)"), &.{"s1"});
    try expectIds(try q.find("ul > :nth-child(4)"), &.{"l3"});
    try expectIds(try q.find("ul > :nth-child(5)"), &.{});
    try expectIds(try q.find("li:nth-child(3)"), &.{});
}

test ":nth-last-child counts from the end" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, list_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    try expectIds(try q.find("ul > :nth-last-child(1)"), &.{"l3"});
    try expectIds(try q.find("ul > :nth-last-child(2)"), &.{"s1"});
    try expectIds(try q.find("ul > :nth-last-child(4)"), &.{"l1"});
    try expectIds(try q.find("li:nth-last-child(2)"), &.{});
}

test ":nth-child with a step still walks the whole run" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, list_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    // Odd positions are 1 and 3; only l1 is an <li>.
    try expectIds(try q.find("li:nth-child(2n+1)"), &.{"l1"});
    try expectIds(try q.find("ul > :nth-child(2n+1)"), &.{ "l1", "s1" });
    try expectIds(try q.find("ul > :nth-child(2n)"), &.{ "l2", "l3" });
    try expectIds(try q.find("ul > :nth-child(odd)"), &.{ "l1", "s1" });
    try expectIds(try q.find("ul > :nth-child(even)"), &.{ "l2", "l3" });
}

test ":nth-of-type counts only same-tag siblings" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, list_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    try expectIds(try q.find("li:nth-of-type(1)"), &.{"l1"});
    try expectIds(try q.find("li:nth-of-type(2)"), &.{"l2"});
    try expectIds(try q.find("li:nth-of-type(3)"), &.{"l3"});
    try expectIds(try q.find("li:nth-of-type(4)"), &.{});
    try expectIds(try q.find("li:nth-last-of-type(1)"), &.{"l3"});
    try expectIds(try q.find("li:nth-last-of-type(3)"), &.{"l1"});
}

test "positional selectors reject a zero or negative literal" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, list_html);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    try expectIds(try q.find(":nth-child(0)"), &.{});
    try expectIds(try q.find(":nth-last-child(0)"), &.{});
}

test "positional selectors on a wide parent stay linear" {
    // 20k siblings. Counting the sibling list per candidate made this
    // quadratic; the neighbour checks make it linear.
    const gpa = std.testing.allocator;
    const count = 20_000;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "<ul>");
    for (0..count) |_| try buf.appendSlice(gpa, "<li>x</li>");
    try buf.appendSlice(gpa, "</ul>");

    var doc = try zq.Document.initFromSlice(gpa, buf.items);
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 1), (try q.find("li:first-child")).len());
    try std.testing.expectEqual(@as(usize, 1), (try q.find("li:last-child")).len());
    try std.testing.expectEqual(@as(usize, 1), (try q.find("li:nth-child(2)")).len());
    try std.testing.expectEqual(@as(usize, 1), (try q.find("li:nth-last-child(2)")).len());
    try std.testing.expectEqual(@as(usize, count), (try q.find("li:first-of-type, li:not(:first-of-type)")).len());
}
