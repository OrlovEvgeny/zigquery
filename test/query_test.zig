//! Query scoping and lifetime.
//!
//! A `Document` owns the DOM; a `Query` owns everything a query produces.
//! The tests here pin down that split, because getting it wrong in the other
//! direction -- putting DOM content in the query arena -- is a use-after-free
//! that no other test would catch.

const std = @import("std");
const zq = @import("zigquery");

const sample =
    \\<html><body>
    \\  <div class="row"><a class="link" href="/one">one</a></div>
    \\  <div class="row"><a class="link" href="/two">two</a></div>
    \\  <div class="other"><span>plain</span></div>
    \\</body></html>
;

test "repeated queries do not grow the document" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, sample);
    defer doc.deinit();

    const before = doc.arena.queryCapacity();

    var q = doc.query(gpa);
    defer q.deinit();
    for (0..2000) |_| {
        const sel = try q.find("div.row a.link");
        try std.testing.expectEqual(@as(usize, 2), sel.len());
    }

    // This is the regression that motivated the split: the same loop used to
    // take the document arena from 43 MB to 243 MB.
    try std.testing.expectEqual(before, doc.arena.queryCapacity());
}

test "query reset returns memory and stays usable" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, sample);
    defer doc.deinit();

    var q = doc.query(gpa);
    defer q.deinit();

    for (0..500) |_| std.mem.doNotOptimizeAway((try q.find("a")).len());
    const peak = q.bytesUsed();
    try std.testing.expect(peak > 0);

    q.reset();
    try std.testing.expectEqual(@as(usize, 2), (try q.find("a")).len());
    try std.testing.expect(q.bytesUsed() <= peak);

    // Reset must not have invalidated the cached selector machinery.
    for (0..500) |_| std.mem.doNotOptimizeAway((try q.find("a")).len());
    try std.testing.expect(q.bytesUsed() <= peak * 2);
}

test "several queries over one document are independent" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, sample);
    defer doc.deinit();

    var first = doc.query(gpa);
    var second = doc.query(gpa);
    defer second.deinit();

    try std.testing.expectEqual(@as(usize, 2), (try first.find("a.link")).len());
    const from_second = try second.find("div.row");
    first.deinit();

    // Ending one query leaves the other, and the document, untouched.
    try std.testing.expectEqual(@as(usize, 2), from_second.len());
    try std.testing.expectEqual(@as(usize, 2), (try second.find("a.link")).len());
}

test "mutations outlive the query that made them" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, sample);
    defer doc.deinit();

    {
        var q = doc.query(gpa);
        defer q.deinit();

        const rows = try q.find("div.row");
        try rows.setAttr("data-seen", "yes");
        try rows.addClass("marked");
        try (try q.find(".other")).appendHtml("<b id=\"added\">bold</b>");
        try (try q.find("span")).setText("replaced");
        try (try q.find("a.link")).wrapHtml("<em></em>");
    }
    // The query is gone; everything it wrote into the DOM must still be valid.

    try zq.tree.validate(gpa, doc.root_node);

    var q2 = doc.query(gpa);
    defer q2.deinit();

    const rows = try q2.find("div.row");
    try std.testing.expectEqual(@as(usize, 2), rows.len());
    try std.testing.expectEqualStrings("yes", rows.attr("data-seen").?);
    try std.testing.expect(rows.hasClass("marked"));
    try std.testing.expectEqual(@as(usize, 1), (try q2.find("#added")).len());
    try std.testing.expectEqualStrings("replaced", try (try q2.find("span")).text());
    try std.testing.expectEqual(@as(usize, 2), (try q2.find("em > a.link")).len());

    // Serializing the whole document re-reads every string the mutations wrote.
    const rendered = try zq.html_render.renderToString(gpa, doc.root_node);
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "data-seen=\"yes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "id=\"added\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "replaced") != null);
}

test "mutations survive a query reset" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, sample);
    defer doc.deinit();

    var q = doc.query(gpa);
    defer q.deinit();

    try (try q.find("div.row")).setAttr("data-k", "v");
    try (try q.find(".other")).setHtml("<i>italic</i>");
    q.reset();

    try zq.tree.validate(gpa, doc.root_node);
    try std.testing.expectEqualStrings("v", (try q.find("div.row")).attr("data-k").?);
    try std.testing.expectEqual(@as(usize, 1), (try q.find(".other > i")).len());
}

test "selector cache returns equivalent results for repeated text" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, sample);
    defer doc.deinit();

    var q = doc.query(gpa);
    defer q.deinit();

    // Caching is keyed on the selector text; a caller's buffer may be reused
    // or freed, so the cache must not hold on to it.
    var buf: [32]u8 = undefined;
    const first_text = try std.fmt.bufPrint(&buf, "{s}", .{"a.link"});
    const a = try q.find(first_text);
    @memset(&buf, 0);
    const second_text = try std.fmt.bufPrint(&buf, "{s}", .{"a.link"});
    const b = try q.find(second_text);

    try std.testing.expectEqual(a.len(), b.len());
    try std.testing.expectEqual(@as(usize, 2), b.len());
}

test "query root is the document root" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, sample);
    defer doc.deinit();

    var q = doc.query(gpa);
    defer q.deinit();

    const root = try q.root();
    try std.testing.expectEqual(@as(usize, 1), root.len());
    try std.testing.expect(root.nodes[0] == doc.root_node);
    try std.testing.expect(root.document() == &doc);
}

// Duplicate suppression marks the nodes themselves instead of building a hash
// set. That only works if every mark is cleared again, so these check both the
// dedup result and the invariant that no mark survives a pass.

fn assertNoMarksLeft(root: *const zq.Node) !void {
    var cur: ?*const zq.Node = root;
    while (cur) |node| : (cur = zq.tree.nextInPreorderConst(node, root)) {
        try std.testing.expectEqual(@as(u32, 0), node.visit_mark);
    }
}

const overlapping =
    \\<div id="outer" class="box">
    \\  <div id="middle" class="box">
    \\    <p class="t">one</p>
    \\    <p class="t">two</p>
    \\  </div>
    \\</div>
;

test "overlapping roots do not yield duplicates" {
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, overlapping);
    defer doc.deinit();
    var q = doc.query(gpa);
    defer q.deinit();

    // Both boxes are in this selection, and one contains the other.
    const boxes = try q.find(".box");
    try std.testing.expectEqual(@as(usize, 2), boxes.len());

    // Each paragraph is a descendant of both, but must appear once.
    try std.testing.expectEqual(@as(usize, 2), (try boxes.find("p.t")).len());
    try assertNoMarksLeft(doc.root_node);

    // Same for the traversal helpers that dedup.
    try std.testing.expectEqual(@as(usize, 3), (try boxes.children()).len());
    try assertNoMarksLeft(doc.root_node);

    const paragraphs = try q.find("p.t");
    try std.testing.expectEqual(@as(usize, 1), (try paragraphs.parent()).len());
    try assertNoMarksLeft(doc.root_node);

    // All ancestors of both paragraphs, deduplicated: #middle, #outer, body, html.
    try std.testing.expectEqual(@as(usize, 4), (try paragraphs.parents()).len());
    try assertNoMarksLeft(doc.root_node);

    try std.testing.expectEqual(@as(usize, 2), (try paragraphs.siblings()).len());
    try assertNoMarksLeft(doc.root_node);

    try std.testing.expectEqual(@as(usize, 1), (try paragraphs.closest(".box")).len());
    try assertNoMarksLeft(doc.root_node);

    const combined = try boxes.addSelection(paragraphs);
    try std.testing.expectEqual(@as(usize, 4), combined.len());
    try assertNoMarksLeft(doc.root_node);
}

fn runDedupPasses(allocator: std.mem.Allocator, doc: *zq.Document) !void {
    var q = doc.query(allocator);
    defer q.deinit();

    const boxes = try q.find(".box");
    _ = try boxes.find("p.t");
    _ = try boxes.children();
    const paragraphs = try q.find("p.t");
    _ = try paragraphs.parent();
    _ = try paragraphs.parents();
    _ = try paragraphs.siblings();
    _ = try paragraphs.closest(".box");
    _ = try boxes.addSelection(paragraphs);
}

test "marks are cleared even when an allocation fails" {
    // Each pass sets marks as it goes and clears them on the way out. An
    // allocation failure partway through must not leave a node marked, or the
    // next query would silently drop it as a duplicate.
    const gpa = std.testing.allocator;
    var doc = try zq.Document.initFromSlice(gpa, overlapping);
    defer doc.deinit();

    var failing_index: usize = 0;
    while (failing_index < 400) : (failing_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = failing_index });
        runDedupPasses(failing.allocator(), &doc) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        };
        try assertNoMarksLeft(doc.root_node);
        if (failing.has_induced_failure == false) break;
    }
    // The loop must actually have induced failures, or it proved nothing.
    try std.testing.expect(failing_index > 0);
}
