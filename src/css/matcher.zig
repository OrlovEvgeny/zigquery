const std = @import("std");
const Allocator = std.mem.Allocator;
const sel_mod = @import("selector.zig");
const Selector = sel_mod.Selector;
const AttrOp = sel_mod.AttrOp;
const CombinatorKind = sel_mod.CombinatorKind;
const PseudoClassKind = sel_mod.PseudoClassKind;
const node_mod = @import("../dom/node.zig");
const Node = node_mod.Node;
const NodeType = node_mod.NodeType;

/// Compiled matcher wrapping a parsed selector. Provides Match, MatchAll,
/// and Filter operations against DOM nodes.
pub const Matcher = struct {
    selector: *const Selector,
    allocator: Allocator,

    pub fn init(allocator: Allocator, selector: *const Selector) Matcher {
        return .{ .selector = selector, .allocator = allocator };
    }

    /// Test if a single node matches this selector.
    pub fn match(self: *const Matcher, node: *const Node) bool {
        return matchNode(self.selector, node);
    }

    /// Find all descendants of `root` that match this selector.
    pub fn matchAll(self: *const Matcher, root: *const Node) ![]*Node {
        var result: std.ArrayList(*Node) = .empty;
        try collectMatches(self.selector, root, &result, self.allocator);
        return result.toOwnedSlice(self.allocator);
    }

    /// Filter a slice of nodes, keeping only those that match.
    pub fn filter(self: *const Matcher, nodes: []*Node) ![]*Node {
        var result: std.ArrayList(*Node) = .empty;
        for (nodes) |n| {
            if (matchNode(self.selector, n)) {
                try result.append(self.allocator, n);
            }
        }
        return result.toOwnedSlice(self.allocator);
    }
};

fn collectMatches(selector: *const Selector, node: *const Node, result: *std.ArrayList(*Node), allocator: Allocator) !void {
    var child = node.first_child;
    while (child) |c| {
        if (c.node_type == .element) {
            if (matchNode(selector, c)) {
                try result.append(allocator, @constCast(c));
            }
            try collectMatches(selector, c, result, allocator);
        }
        child = c.next_sibling;
    }
}

/// Core matching logic: does `selector` match `node`?
pub fn matchNode(selector: *const Selector, node: *const Node) bool {
    if (node.node_type != .element) {
        return switch (selector.*) {
            .universal => true,
            else => false,
        };
    }

    return switch (selector.*) {
        .tag => |tag| std.mem.eql(u8, node.data, tag),
        .id => |id| blk: {
            const node_id = node.getAttr("id") orelse break :blk false;
            break :blk std.mem.eql(u8, node_id, id);
        },
        .class => |cls| hasClass(node, cls),
        .universal => true,
        .attr => |attr_sel| matchAttr(node, attr_sel),
        .pseudo_class => |pc| matchPseudoClass(node, pc),
        .combinator => |comb| matchCombinator(node, comb),
        .compound => |parts| blk: {
            for (parts) |part| {
                if (!matchNode(part, node)) break :blk false;
            }
            break :blk true;
        },
        .group => |parts| blk: {
            for (parts) |part| {
                if (matchNode(part, node)) break :blk true;
            }
            break :blk false;
        },
        .not => |inner| !matchNode(inner, node),
        .has_pseudo => |inner| matchHas(node, inner),
        .contains => |text| matchContains(node, text),
    };
}

fn hasClass(node: *const Node, cls: []const u8) bool {
    const class_attr = node.getAttr("class") orelse return false;
    var it = std.mem.splitScalar(u8, class_attr, ' ');
    while (it.next()) |part| {
        // Also split on tabs/newlines.
        var inner = std.mem.tokenizeAny(u8, part, "\t\n\r");
        while (inner.next()) |token| {
            if (std.mem.eql(u8, token, cls)) return true;
        }
    }
    return false;
}

fn matchAttr(node: *const Node, attr_sel: sel_mod.AttrSelector) bool {
    for (node.attr) |attr| {
        if (!std.mem.eql(u8, attr.key, attr_sel.key)) continue;

        return switch (attr_sel.op) {
            .exists => true,
            .equals => eqlMaybeCI(attr.val, attr_sel.val, attr_sel.case_insensitive),
            .includes => blk: {
                var it = std.mem.tokenizeAny(u8, attr.val, " \t\n\r");
                while (it.next()) |word| {
                    if (eqlMaybeCI(word, attr_sel.val, attr_sel.case_insensitive)) break :blk true;
                }
                break :blk false;
            },
            .dash_match => blk: {
                if (eqlMaybeCI(attr.val, attr_sel.val, attr_sel.case_insensitive)) break :blk true;
                if (attr.val.len > attr_sel.val.len and attr.val[attr_sel.val.len] == '-') {
                    break :blk eqlMaybeCI(attr.val[0..attr_sel.val.len], attr_sel.val, attr_sel.case_insensitive);
                }
                break :blk false;
            },
            .prefix => blk: {
                if (attr.val.len < attr_sel.val.len) break :blk false;
                break :blk eqlMaybeCI(attr.val[0..attr_sel.val.len], attr_sel.val, attr_sel.case_insensitive);
            },
            .suffix => blk: {
                if (attr.val.len < attr_sel.val.len) break :blk false;
                break :blk eqlMaybeCI(attr.val[attr.val.len - attr_sel.val.len ..], attr_sel.val, attr_sel.case_insensitive);
            },
            .substring => blk: {
                if (attr_sel.case_insensitive) {
                    // Brute force case-insensitive substring.
                    if (attr.val.len < attr_sel.val.len) break :blk false;
                    var i: usize = 0;
                    while (i + attr_sel.val.len <= attr.val.len) : (i += 1) {
                        if (eqlMaybeCI(attr.val[i .. i + attr_sel.val.len], attr_sel.val, true)) break :blk true;
                    }
                    break :blk false;
                }
                break :blk std.mem.indexOf(u8, attr.val, attr_sel.val) != null;
            },
        };
    }
    return false;
}

fn eqlMaybeCI(a: []const u8, b: []const u8, case_insensitive: bool) bool {
    if (case_insensitive) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

fn matchPseudoClass(node: *const Node, pc: sel_mod.PseudoClassSelector) bool {
    return switch (pc.kind) {
        .first_child => isNthChild(node, 0, 1, false),
        .last_child => isNthChild(node, 0, 1, true),
        .only_child => isNthChild(node, 0, 1, false) and isNthChild(node, 0, 1, true),
        .first_of_type => isNthOfType(node, 0, 1, false),
        .last_of_type => isNthOfType(node, 0, 1, true),
        .only_of_type => isNthOfType(node, 0, 1, false) and isNthOfType(node, 0, 1, true),
        .empty => nodeIsEmpty(node),
        .root => node.parent != null and (node.parent.?.node_type == .document),
        .nth_child => isNthChild(node, pc.a, pc.b, false),
        .nth_last_child => isNthChild(node, pc.a, pc.b, true),
        .nth_of_type => isNthOfType(node, pc.a, pc.b, false),
        .nth_last_of_type => isNthOfType(node, pc.a, pc.b, true),
        .enabled => !matchAttrVal(node, "disabled", ""),
        .disabled => matchAttrVal(node, "disabled", "") or node.getAttr("disabled") != null,
        .checked => node.getAttr("checked") != null or node.getAttr("selected") != null,
    };
}

fn isNthChild(node: *const Node, a: i32, b: i32, from_end: bool) bool {
    const parent = node.parent orelse return false;
    var index: i32 = 0;

    if (from_end) {
        var c = parent.last_child;
        while (c) |child| : (c = child.prev_sibling) {
            if (child.node_type == .element) {
                index += 1;
                if (child == @as(*const Node, node)) return matchesNth(a, b, index);
            }
        }
    } else {
        var c = parent.first_child;
        while (c) |child| : (c = child.next_sibling) {
            if (child.node_type == .element) {
                index += 1;
                if (child == @as(*const Node, node)) return matchesNth(a, b, index);
            }
        }
    }
    return false;
}

fn isNthOfType(node: *const Node, a: i32, b: i32, from_end: bool) bool {
    const parent = node.parent orelse return false;
    var index: i32 = 0;

    if (from_end) {
        var c = parent.last_child;
        while (c) |child| : (c = child.prev_sibling) {
            if (child.node_type == .element and std.mem.eql(u8, child.data, node.data)) {
                index += 1;
                if (child == @as(*const Node, node)) return matchesNth(a, b, index);
            }
        }
    } else {
        var c = parent.first_child;
        while (c) |child| : (c = child.next_sibling) {
            if (child.node_type == .element and std.mem.eql(u8, child.data, node.data)) {
                index += 1;
                if (child == @as(*const Node, node)) return matchesNth(a, b, index);
            }
        }
    }
    return false;
}

fn matchesNth(a: i32, b: i32, index: i32) bool {
    if (a == 0) return index == b;
    const diff = index - b;
    if (@rem(diff, a) != 0) return false;
    return @divTrunc(diff, a) >= 0;
}

fn nodeIsEmpty(node: *const Node) bool {
    var c = node.first_child;
    while (c) |child| : (c = child.next_sibling) {
        switch (child.node_type) {
            .element => return false,
            .text => {
                if (child.data.len > 0) return false;
            },
            else => {},
        }
    }
    return true;
}

fn matchAttrVal(node: *const Node, key: []const u8, _: []const u8) bool {
    return node.getAttr(key) != null;
}

fn matchCombinator(node: *const Node, comb: sel_mod.Combinator) bool {
    // The right selector must match the current node.
    if (!matchNode(comb.right, node)) return false;

    return switch (comb.kind) {
        .descendant => blk: {
            var p = node.parent;
            while (p) |parent| {
                if (parent.node_type == .element and matchNode(comb.left, parent)) break :blk true;
                p = parent.parent;
            }
            break :blk false;
        },
        .child => blk: {
            const parent = node.parent orelse break :blk false;
            break :blk parent.node_type == .element and matchNode(comb.left, parent);
        },
        .next_sibling => blk: {
            var prev = node.prev_sibling;
            while (prev) |p| {
                if (p.node_type == .element) break :blk matchNode(comb.left, p);
                prev = p.prev_sibling;
            }
            break :blk false;
        },
        .subsequent_sibling => blk: {
            var prev = node.prev_sibling;
            while (prev) |p| {
                if (p.node_type == .element and matchNode(comb.left, p)) break :blk true;
                prev = p.prev_sibling;
            }
            break :blk false;
        },
    };
}

fn matchHas(node: *const Node, inner: *const Selector) bool {
    var child = node.first_child;
    while (child) |c| {
        if (c.node_type == .element) {
            if (matchNode(inner, c)) return true;
            if (matchHas(c, inner)) return true;
        }
        child = c.next_sibling;
    }
    return false;
}

fn matchContains(node: *const Node, text: []const u8) bool {
    return nodeContainsText(node, text);
}

fn nodeContainsText(node: *const Node, text: []const u8) bool {
    if (node.node_type == .text) {
        return std.mem.indexOf(u8, node.data, text) != null;
    }
    var c = node.first_child;
    while (c) |child| {
        if (nodeContainsText(child, text)) return true;
        c = child.next_sibling;
    }
    return false;
}

test "match tag selector" {
    const attr_arr = [_]node_mod.Attribute{};
    var node = Node{
        .node_type = .element,
        .data = "div",
        .attr = @constCast(&attr_arr),
    };
    const selector = Selector{ .tag = "div" };
    try std.testing.expect(matchNode(&selector, &node));

    const selector2 = Selector{ .tag = "span" };
    try std.testing.expect(!matchNode(&selector2, &node));
}

test "match class selector" {
    const attrs = [_]node_mod.Attribute{
        .{ .key = "class", .val = "foo bar baz" },
    };
    var node = Node{
        .node_type = .element,
        .data = "div",
        .attr = @constCast(&attrs),
    };

    const sel_foo = Selector{ .class = "foo" };
    try std.testing.expect(matchNode(&sel_foo, &node));

    const sel_bar = Selector{ .class = "bar" };
    try std.testing.expect(matchNode(&sel_bar, &node));

    const sel_nope = Selector{ .class = "nope" };
    try std.testing.expect(!matchNode(&sel_nope, &node));
}

test "match id selector" {
    const attrs = [_]node_mod.Attribute{
        .{ .key = "id", .val = "main" },
    };
    var node = Node{
        .node_type = .element,
        .data = "div",
        .attr = @constCast(&attrs),
    };

    const sel = Selector{ .id = "main" };
    try std.testing.expect(matchNode(&sel, &node));

    const sel2 = Selector{ .id = "other" };
    try std.testing.expect(!matchNode(&sel2, &node));
}

test "match universal selector" {
    var node = Node{ .node_type = .element, .data = "anything" };
    const sel = Selector{ .universal = {} };
    try std.testing.expect(matchNode(&sel, &node));
}

test "match attribute exists" {
    const attrs = [_]node_mod.Attribute{
        .{ .key = "disabled", .val = "" },
    };
    var node = Node{ .node_type = .element, .data = "input", .attr = @constCast(&attrs) };

    const sel = Selector{ .attr = .{ .key = "disabled" } };
    try std.testing.expect(matchNode(&sel, &node));
}

test "match :empty pseudo-class" {
    var node = Node{ .node_type = .element, .data = "div" };
    const sel = Selector{ .pseudo_class = .{ .kind = .empty } };
    try std.testing.expect(matchNode(&sel, &node));
}

test "matchAll collects descendants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tree_mod = @import("../dom/tree.zig");

    var root = Node{ .node_type = .element, .data = "div" };
    var child1 = Node{ .node_type = .element, .data = "p" };
    var child2 = Node{ .node_type = .element, .data = "p" };
    var child3 = Node{ .node_type = .element, .data = "span" };
    tree_mod.appendChild(&root, &child1);
    tree_mod.appendChild(&root, &child2);
    tree_mod.appendChild(&root, &child3);

    const sel = Selector{ .tag = "p" };
    const m = Matcher.init(alloc, &sel);
    const results = try m.matchAll(&root);
    try std.testing.expect(results.len == 2);
}
