const std = @import("std");
const zq = @import("zigquery");
const helper = @import("test_helper.zig");

test "Selection.len" {
    var doc = try helper.parseDoc("<div><p>1</p><p>2</p><p>3</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const sel = try q.find("p");
    try std.testing.expect(sel.len() == 3);
}

test "Selection.first" {
    var doc = try helper.parseDoc("<ul><li>A</li><li>B</li><li>C</li></ul>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const lis = try q.find("li");
    const first = try lis.first();
    try std.testing.expect(first.len() == 1);
    const t = try first.text();
    try std.testing.expectEqualStrings("A", t);
}

test "Selection.last" {
    var doc = try helper.parseDoc("<ul><li>A</li><li>B</li><li>C</li></ul>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const lis = try q.find("li");
    const last = try lis.last();
    try std.testing.expect(last.len() == 1);
    const t = try last.text();
    try std.testing.expectEqualStrings("C", t);
}

test "Selection.eq" {
    var doc = try helper.parseDoc("<ul><li>A</li><li>B</li><li>C</li></ul>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const lis = try q.find("li");
    const second = try lis.eq(1);
    try std.testing.expect(second.len() == 1);
    const t = try second.text();
    try std.testing.expectEqualStrings("B", t);
}

test "Selection.eq negative index" {
    var doc = try helper.parseDoc("<ul><li>A</li><li>B</li><li>C</li></ul>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const lis = try q.find("li");
    const last = try lis.eq(-1);
    try std.testing.expect(last.len() == 1);
    const t = try last.text();
    try std.testing.expectEqualStrings("C", t);
}

test "Selection.get" {
    var doc = try helper.parseDoc("<ul><li>A</li><li>B</li></ul>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const lis = try q.find("li");
    const node = lis.get(0).?;
    try std.testing.expectEqualStrings("li", node.data);
    try std.testing.expect(lis.get(5) == null);
}

test "Selection.slice" {
    var doc = try helper.parseDoc("<ul><li>A</li><li>B</li><li>C</li><li>D</li></ul>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const lis = try q.find("li");
    const middle = try lis.sliceRange(1, 3);
    try std.testing.expect(middle.len() == 2);
}

test "Selection.each" {
    var doc = try helper.parseDoc("<ul><li>A</li><li>B</li></ul>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const lis = try q.find("li");
    var count: usize = 0;
    const counter_fn = struct {
        fn f(_: usize, _: zq.Selection) void {
            // Can't capture, just verify it doesn't crash.
        }
    }.f;
    lis.each(counter_fn);
    _ = &count;
}

test "Selection.iterator" {
    var doc = try helper.parseDoc("<ul><li>A</li><li>B</li><li>C</li></ul>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const lis = try q.find("li");
    var it = lis.iterator();
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expect(count == 3);
}

test "empty selection operations" {
    var doc = try helper.parseDoc("<div></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const empty = try q.find("nonexistent");
    try std.testing.expect(empty.len() == 0);
    try std.testing.expect((try empty.first()).len() == 0);
    try std.testing.expect((try empty.last()).len() == 0);
    try std.testing.expect(empty.attr("id") == null);
    try std.testing.expect(!empty.hasClass("foo"));
    try std.testing.expect(!try empty.is("div"));
    try std.testing.expect(empty.get(0) == null);
    try std.testing.expect(empty.index() == null);
}

test "Selection.end returns previous" {
    var doc = try helper.parseDoc("<div><p>A</p></div>");
    defer doc.deinit();
    var q = doc.query(std.testing.allocator);
    defer q.deinit();
    const div = try q.find("div");
    const p_sel = try div.children();
    try std.testing.expect(p_sel.len() == 1);
    const back = p_sel.end();
    try std.testing.expect(back.len() == 1);
    try std.testing.expectEqualStrings("div", back.nodes[0].data);
}
