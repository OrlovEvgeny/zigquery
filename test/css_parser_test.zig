const std = @import("std");
const zq = @import("zigquery");

test "parse and match tag selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try zq.css_parser.parseSelector(arena.allocator(), "div");
    try std.testing.expect(sel.* == .tag);
    try std.testing.expectEqualStrings("div", sel.tag);
}

test "parse and match class selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try zq.css_parser.parseSelector(arena.allocator(), ".active");
    try std.testing.expect(sel.* == .class);
    try std.testing.expectEqualStrings("active", sel.class);
}

test "parse complex selector div > p.intro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try zq.css_parser.parseSelector(arena.allocator(), "div > p.intro");
    try std.testing.expect(sel.* == .combinator);
    try std.testing.expect(sel.combinator.kind == .child);
}

test "parse sibling selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try zq.css_parser.parseSelector(arena.allocator(), "h1 + p");
    try std.testing.expect(sel.* == .combinator);
    try std.testing.expect(sel.combinator.kind == .next_sibling);

    const sel2 = try zq.css_parser.parseSelector(arena.allocator(), "h1 ~ p");
    try std.testing.expect(sel2.* == .combinator);
    try std.testing.expect(sel2.combinator.kind == .subsequent_sibling);
}

test "parse attribute selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sel1 = try zq.css_parser.parseSelector(arena.allocator(), "[href]");
    try std.testing.expect(sel1.* == .attr);
    try std.testing.expect(sel1.attr.op == .exists);

    const sel2 = try zq.css_parser.parseSelector(arena.allocator(), "[type=\"text\"]");
    try std.testing.expect(sel2.* == .attr);
    try std.testing.expect(sel2.attr.op == .equals);

    const sel3 = try zq.css_parser.parseSelector(arena.allocator(), "[class~=\"foo\"]");
    try std.testing.expect(sel3.* == .attr);
    try std.testing.expect(sel3.attr.op == .includes);

    const sel4 = try zq.css_parser.parseSelector(arena.allocator(), "[href^=\"https\"]");
    try std.testing.expect(sel4.* == .attr);
    try std.testing.expect(sel4.attr.op == .prefix);

    const sel5 = try zq.css_parser.parseSelector(arena.allocator(), "[href$=\".html\"]");
    try std.testing.expect(sel5.* == .attr);
    try std.testing.expect(sel5.attr.op == .suffix);
}

test "parse pseudo-class selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sel = try zq.css_parser.parseSelector(arena.allocator(), ":first-child");
    try std.testing.expect(sel.* == .pseudo_class);

    const sel2 = try zq.css_parser.parseSelector(arena.allocator(), ":nth-child(odd)");
    try std.testing.expect(sel2.* == .pseudo_class);
    try std.testing.expect(sel2.pseudo_class.a == 2);
    try std.testing.expect(sel2.pseudo_class.b == 1);

    const sel3 = try zq.css_parser.parseSelector(arena.allocator(), ":nth-child(even)");
    try std.testing.expect(sel3.* == .pseudo_class);
    try std.testing.expect(sel3.pseudo_class.a == 2);
    try std.testing.expect(sel3.pseudo_class.b == 0);
}

test "parse :not pseudo-class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try zq.css_parser.parseSelector(arena.allocator(), ":not(.hidden)");
    try std.testing.expect(sel.* == .not);
}

test "parse group selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try zq.css_parser.parseSelector(arena.allocator(), "h1, h2, h3");
    try std.testing.expect(sel.* == .group);
    try std.testing.expect(sel.group.len == 3);
}

test "invalid selector returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = zq.css_parser.parseSelector(arena.allocator(), "");
    try std.testing.expectError(error.UnexpectedToken, result);
}
