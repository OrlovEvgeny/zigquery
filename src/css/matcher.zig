const std = @import("std");
const Allocator = std.mem.Allocator;
const sel_mod = @import("selector.zig");
const Selector = sel_mod.Selector;
const AttrOp = sel_mod.AttrOp;
const CombinatorKind = sel_mod.CombinatorKind;
const PseudoClassKind = sel_mod.PseudoClassKind;
const tree = @import("../dom/tree.zig");
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
    var cur = tree.nextInPreorderConst(node, node);
    while (cur) |current| : (cur = tree.nextInPreorderConst(current, node)) {
        if (current.node_type == .element and matchNode(selector, current)) {
            try result.append(allocator, @constCast(current));
        }
    }
}

/// Core matching logic: does `selector` match `node`?
pub fn matchNode(selector: *const Selector, node: *const Node) bool {
    if (node.node_type != .element) return false;

    return switch (selector.*) {
        .tag => |tag| std.ascii.eqlIgnoreCase(node.data, tag),
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
        .relative => false,
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
        if (!std.ascii.eqlIgnoreCase(attr.key, attr_sel.key)) continue;

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
                if (attr_sel.val.len == 0) break :blk false;
                if (attr.val.len < attr_sel.val.len) break :blk false;
                break :blk eqlMaybeCI(attr.val[0..attr_sel.val.len], attr_sel.val, attr_sel.case_insensitive);
            },
            .suffix => blk: {
                if (attr_sel.val.len == 0) break :blk false;
                if (attr.val.len < attr_sel.val.len) break :blk false;
                break :blk eqlMaybeCI(attr.val[attr.val.len - attr_sel.val.len ..], attr_sel.val, attr_sel.case_insensitive);
            },
            .substring => blk: {
                if (attr_sel.val.len == 0) break :blk false;
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
        // The positional pseudo-classes below are answered by looking at the
        // immediate neighbours rather than by counting the whole sibling list.
        // Counting made matching a wide parent quadratic in its child count.
        .first_child => siblingElement(node, .previous, null) == null,
        .last_child => siblingElement(node, .next, null) == null,
        .only_child => siblingElement(node, .previous, null) == null and
            siblingElement(node, .next, null) == null,
        .first_of_type => siblingElement(node, .previous, node.data) == null,
        .last_of_type => siblingElement(node, .next, node.data) == null,
        .only_of_type => siblingElement(node, .previous, node.data) == null and
            siblingElement(node, .next, node.data) == null,
        .empty => nodeIsEmpty(node),
        .root => node.parent != null and (node.parent.?.node_type == .document),
        .nth_child => isNthChild(node, pc.a, pc.b, false),
        .nth_last_child => isNthChild(node, pc.a, pc.b, true),
        .nth_of_type => isNthOfType(node, pc.a, pc.b, false),
        .nth_last_of_type => isNthOfType(node, pc.a, pc.b, true),
        .enabled => isDisableable(node) and node.getAttr("disabled") == null,
        .disabled => isDisableable(node) and node.getAttr("disabled") != null,
        .checked => (std.mem.eql(u8, node.data, "input") and node.getAttr("checked") != null) or
            (std.mem.eql(u8, node.data, "option") and node.getAttr("selected") != null),
    };
}

const Direction = enum { previous, next };

/// Nearest element sibling in `dir`, optionally restricted to a tag name.
/// Returns null when there is none.
fn siblingElement(node: *const Node, comptime dir: Direction, of_type: ?[]const u8) ?*const Node {
    var cur = switch (dir) {
        .previous => node.prev_sibling,
        .next => node.next_sibling,
    };
    while (cur) |current| {
        if (current.node_type == .element) {
            if (of_type) |tag| {
                if (std.mem.eql(u8, current.data, tag)) return current;
            } else {
                return current;
            }
        }
        cur = switch (dir) {
            .previous => current.prev_sibling,
            .next => current.next_sibling,
        };
    }
    return null;
}

/// Remembers where the last position query landed, so walking a sibling list in
/// document order costs one step per element instead of a rescan.
///
/// Both memos are validated against `tree.structure_generation`, so any
/// insertion or removal anywhere invalidates them. That is deliberately
/// conservative: a stale position would silently produce wrong matches.
const PositionMemo = struct {
    generation: u64 = std.math.maxInt(u64),
    parent: ?*const Node = null,
    node: ?*const Node = null,
    index: i32 = 0,
    of_type: ?[]const u8 = null,
};

const CountMemo = struct {
    generation: u64 = std.math.maxInt(u64),
    parent: ?*const Node = null,
    of_type: ?[]const u8 = null,
    count: i32 = 0,
};

/// A pre-order walk descends into each child's subtree before reaching the
/// next sibling, so a single memo slot is evicted by the nested subtree and
/// never hits. Enough slots to cover the parents along the current path -- plus
/// the ones just finished -- keeps the sibling walk O(1) amortized.
const memo_slots = 128;

threadlocal var position_memo: [memo_slots]PositionMemo = @splat(.{});
threadlocal var count_memo: [memo_slots]CountMemo = @splat(.{});

fn memoSlot(parent: *const Node) usize {
    // Nodes come from an arena, so consecutive ones sit a fixed stride apart
    // and the low bits are alignment padding. Mix before masking, or whole
    // runs of siblings land in the same slot.
    const mixed = @as(u64, @intFromPtr(parent) >> 3) *% 0x9E3779B97F4A7C15;
    return @intCast((mixed >> 32) % memo_slots);
}

fn sameOfType(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null) return b == null;
    if (b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// 1-based position of `node` among its element siblings, counting from the
/// start, optionally restricted to siblings sharing `of_type`.
///
/// Counting from scratch on every call made matching a parent with S children
/// cost O(S^2): `:nth-child(2n+1)` over 100k siblings took 31 seconds.
fn elementPosition(node: *const Node, of_type: ?[]const u8) ?i32 {
    const parent = node.parent orelse return null;
    const slot = &position_memo[memoSlot(parent)];
    const memo_valid = slot.generation == tree.structure_generation and
        slot.parent == parent and
        sameOfType(slot.of_type, of_type);

    // Walk back toward the start, but stop as soon as we reach the sibling
    // whose position we worked out last time under this parent. Matching moves
    // forward through a sibling list, so that is usually only a step or two --
    // whereas restarting from the first child every time is what made this
    // O(S^2) for a parent with S children.
    var index: i32 = 0;
    var steps: i32 = 0;
    var cur = siblingElement(node, .previous, of_type);
    while (cur) |current| : (cur = siblingElement(current, .previous, of_type)) {
        steps += 1;
        if (memo_valid and slot.node == current) {
            index = slot.index + steps;
            break;
        }
    }
    if (index == 0) index = steps + 1;

    slot.* = .{
        .generation = tree.structure_generation,
        .parent = parent,
        .node = node,
        .index = index,
        .of_type = of_type,
    };
    return index;
}

/// How many element children `parent` has, optionally restricted by tag.
fn elementCount(parent: *const Node, of_type: ?[]const u8) i32 {
    const slot = &count_memo[memoSlot(parent)];
    if (slot.generation == tree.structure_generation and
        slot.parent == parent and
        sameOfType(slot.of_type, of_type))
    {
        return slot.count;
    }

    var count: i32 = 0;
    var child = parent.first_child;
    while (child) |current| : (child = current.next_sibling) {
        if (current.node_type != .element) continue;
        if (of_type) |tag| {
            if (!std.mem.eql(u8, current.data, tag)) continue;
        }
        count += 1;
    }

    slot.* = .{
        .generation = tree.structure_generation,
        .parent = parent,
        .of_type = of_type,
        .count = count,
    };
    return count;
}

/// Position counted from whichever end the selector asks for.
fn positionFor(node: *const Node, from_end: bool, of_type: ?[]const u8) ?i32 {
    const forward = elementPosition(node, of_type) orelse return null;
    if (!from_end) return forward;
    // Counting backward from a forward position avoids a second memo that
    // would never hit: matching walks siblings forward, not backward.
    return elementCount(node.parent.?, of_type) - forward + 1;
}

fn isNthChild(node: *const Node, a: i32, b: i32, from_end: bool) bool {
    // With no step, only position `b` can match, so walking more than `b`
    // siblings is wasted work. Anything at or before position `b` is found
    // within `b` steps; anything after it is rejected just as quickly.
    if (a == 0) return isAtPosition(node, b, from_end, null);
    const index = positionFor(node, from_end, null) orelse return false;
    return matchesNth(a, b, index);
}

fn isNthOfType(node: *const Node, a: i32, b: i32, from_end: bool) bool {
    if (a == 0) return isAtPosition(node, b, from_end, node.data);
    const index = positionFor(node, from_end, node.data) orelse return false;
    return matchesNth(a, b, index);
}

/// Is `node` exactly at 1-based position `b` among its element siblings
/// (counting from the end when `from_end`), optionally among siblings sharing
/// its tag name? Costs at most `b` steps rather than a full sibling scan.
fn isAtPosition(node: *const Node, b: i32, from_end: bool, of_type: ?[]const u8) bool {
    if (b <= 0) return false;
    if (node.parent == null) return false;

    var remaining = b - 1;
    var cur: ?*const Node = node;
    while (remaining > 0) : (remaining -= 1) {
        cur = if (from_end)
            siblingElement(cur.?, .next, of_type)
        else
            siblingElement(cur.?, .previous, of_type);
        if (cur == null) return false;
    }
    // `cur` is now `b - 1` steps toward the relevant end; the node is at
    // position `b` exactly when nothing lies beyond it.
    return if (from_end)
        siblingElement(cur.?, .next, of_type) == null
    else
        siblingElement(cur.?, .previous, of_type) == null;
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

fn isDisableable(node: *const Node) bool {
    const disableable = [_][]const u8{ "button", "fieldset", "input", "optgroup", "option", "select", "textarea" };
    for (disableable) |name| {
        if (std.mem.eql(u8, node.data, name)) return true;
    }
    return false;
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
    return switch (inner.*) {
        .group => |parts| blk: {
            for (parts) |part| {
                if (matchHas(node, part)) break :blk true;
            }
            break :blk false;
        },
        .relative => |relative| matchRelative(node, relative),
        else => matchRelative(node, .{ .kind = .descendant, .selector = inner }),
    };
}

/// Evaluate a `:has()` relative selector against `node`.
///
/// The candidate set is scoped by the leading combinator rather than searched
/// for across the whole document:
///
///   * `:has(a)` / `:has(> a)` -- every match lies inside the anchor's own
///     subtree. Sibling combinators inside the relative selector move between
///     children of the anchor, so they cannot escape it either.
///   * `:has(+ a)` / `:has(~ a)` -- the match lies in a following sibling or
///     one of their subtrees, so those are scanned instead.
///
/// Scanning the entire document per anchor, as this used to, makes `:has()`
/// quadratic in document size: about a second per call on a 2 MB page, against
/// well under a millisecond for every other selector.
fn matchRelative(node: *const Node, relative: sel_mod.RelativeSelector) bool {
    return switch (relative.kind) {
        .descendant, .child => anyCandidateInSubtree(node, relative, node),
        .next_sibling, .subsequent_sibling => blk: {
            // Both sibling combinators scan every following sibling, not just
            // the immediate one: `:has(+ p ~ span)` anchors `p` to the next
            // sibling but matches `span`, a later sibling still. The
            // "immediate" versus "any" distinction is enforced where it
            // belongs, by `matchesLeadingRelation` on the leftmost compound.
            var sibling = nextElementSibling(node);
            while (sibling) |current| : (sibling = nextElementSibling(current)) {
                if (matchRelativeCandidate(node, relative.kind, relative.selector, current)) break :blk true;
                if (anyCandidateInSubtree(node, relative, current)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// Test every strict descendant of `root` as a candidate. Iterative, so a
/// deeply nested document cannot overflow the stack.
fn anyCandidateInSubtree(
    anchor: *const Node,
    relative: sel_mod.RelativeSelector,
    root: *const Node,
) bool {
    var cur: ?*const Node = root.first_child;
    while (cur) |current| : (cur = tree.nextInPreorderConst(current, root)) {
        if (current.node_type != .element) continue;
        if (matchRelativeCandidate(anchor, relative.kind, relative.selector, current)) return true;
    }
    return false;
}

fn nextElementSibling(node: *const Node) ?*const Node {
    var sibling = node.next_sibling;
    while (sibling) |current| : (sibling = current.next_sibling) {
        if (current.node_type == .element) return current;
    }
    return null;
}

fn matchRelativeCandidate(anchor: *const Node, leading: CombinatorKind, selector: *const Selector, candidate: *const Node) bool {
    if (candidate.node_type != .element) return false;
    return switch (selector.*) {
        .combinator => |comb| blk: {
            if (!matchNode(comb.right, candidate)) break :blk false;
            break :blk switch (comb.kind) {
                .descendant => descendant: {
                    var parent = candidate.parent;
                    while (parent) |current| : (parent = current.parent) {
                        if (matchRelativeCandidate(anchor, leading, comb.left, current)) break :descendant true;
                    }
                    break :descendant false;
                },
                .child => if (candidate.parent) |parent|
                    matchRelativeCandidate(anchor, leading, comb.left, parent)
                else
                    false,
                .next_sibling => previous: {
                    var sibling = candidate.prev_sibling;
                    while (sibling) |current| : (sibling = current.prev_sibling) {
                        if (current.node_type == .element) {
                            break :previous matchRelativeCandidate(anchor, leading, comb.left, current);
                        }
                    }
                    break :previous false;
                },
                .subsequent_sibling => previous: {
                    var sibling = candidate.prev_sibling;
                    while (sibling) |current| : (sibling = current.prev_sibling) {
                        if (current.node_type == .element and
                            matchRelativeCandidate(anchor, leading, comb.left, current)) break :previous true;
                    }
                    break :previous false;
                },
            };
        },
        // `matchNode` is a tag/class/attribute test on this one node, while
        // `matchesLeadingRelation` may walk every ancestor. Cheap test first.
        else => matchNode(selector, candidate) and matchesLeadingRelation(anchor, candidate, leading),
    };
}

fn matchesLeadingRelation(anchor: *const Node, candidate: *const Node, leading: CombinatorKind) bool {
    return switch (leading) {
        .descendant => blk: {
            var parent = candidate.parent;
            while (parent) |current| : (parent = current.parent) {
                if (current == anchor) break :blk true;
            }
            break :blk false;
        },
        .child => candidate.parent == anchor,
        .next_sibling => blk: {
            var sibling = candidate.prev_sibling;
            while (sibling) |current| : (sibling = current.prev_sibling) {
                if (current.node_type == .element) break :blk current == anchor;
            }
            break :blk false;
        },
        .subsequent_sibling => blk: {
            var sibling = candidate.prev_sibling;
            while (sibling) |current| : (sibling = current.prev_sibling) {
                if (current.node_type == .element and current == anchor) break :blk true;
            }
            break :blk false;
        },
    };
}

fn matchContains(node: *const Node, text: []const u8) bool {
    return nodeContainsText(node, text);
}

fn nodeContainsText(node: *const Node, text: []const u8) bool {
    if (node.node_type == .text) {
        return std.mem.indexOf(u8, node.data, text) != null;
    }
    var cur = tree.nextInPreorderConst(node, node);
    while (cur) |current| : (cur = tree.nextInPreorderConst(current, node)) {
        if (current.node_type == .text and std.mem.indexOf(u8, current.data, text) != null) return true;
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

// ---------------------------------------------------------------------------
// Differential tests for the memoized sibling positions.
//
// `elementPosition` and `elementCount` cache across calls, so a bug in them
// shows up only for particular visit orders. These tests compare every
// positional pseudo-class against a straightforward rescanning implementation
// over trees with mixed node types, checking every node in several orders.
// ---------------------------------------------------------------------------

/// Deliberately naive: rescans the sibling list on every call.
fn referencePosition(node: *const Node, from_end: bool, of_type: ?[]const u8) ?i32 {
    const parent = node.parent orelse return null;
    var index: i32 = 0;
    var child = if (from_end) parent.last_child else parent.first_child;
    while (child) |current| : (child = if (from_end) current.prev_sibling else current.next_sibling) {
        if (current.node_type != .element) continue;
        if (of_type) |tag| {
            if (!std.mem.eql(u8, current.data, tag)) continue;
        }
        index += 1;
        if (current == node) return index;
    }
    return null;
}

const PositionCase = struct { from_end: bool, of_type: bool };

fn checkPositionsAgainstReference(root: *const Node) !void {
    const cases = [_]PositionCase{
        .{ .from_end = false, .of_type = false },
        .{ .from_end = true, .of_type = false },
        .{ .from_end = false, .of_type = true },
        .{ .from_end = true, .of_type = true },
    };

    for (cases) |case| {
        var cur: ?*const Node = root;
        while (cur) |node| : (cur = tree.nextInPreorderConst(node, root)) {
            if (node.node_type != .element) continue;
            const of_type: ?[]const u8 = if (case.of_type) node.data else null;
            const want = referencePosition(node, case.from_end, of_type);
            const got = positionFor(node, case.from_end, of_type);
            try std.testing.expectEqual(want, got);
        }
    }
}

fn buildMixedTree(gpa: std.mem.Allocator, seed: u64) !*Node {
    // Element tags repeat so `of_type` counting has something to skip over,
    // and text/comment nodes are interleaved so they must not be counted.
    const tags = [_][]const u8{ "div", "p", "span", "div", "li" };
    var state = seed | 1;
    const rand = struct {
        fn next(x: *u64) u64 {
            x.* ^= x.* << 13;
            x.* ^= x.* >> 7;
            x.* ^= x.* << 17;
            return x.*;
        }
    };

    const root = try gpa.create(Node);
    root.* = .{ .node_type = .element, .data = "root" };

    var parents: std.ArrayList(*Node) = .empty;
    defer parents.deinit(gpa);
    try parents.append(gpa, root);

    var made: usize = 0;
    while (made < 120) : (made += 1) {
        const parent = parents.items[rand.next(&state) % parents.items.len];
        const roll = rand.next(&state) % 10;
        const node = try gpa.create(Node);
        if (roll < 6) {
            node.* = .{ .node_type = .element, .data = tags[rand.next(&state) % tags.len] };
            tree.appendChild(parent, node);
            if (parents.items.len < 12) try parents.append(gpa, node);
        } else if (roll < 8) {
            node.* = .{ .node_type = .text, .data = "t" };
            tree.appendChild(parent, node);
        } else {
            node.* = .{ .node_type = .comment, .data = "c" };
            tree.appendChild(parent, node);
        }
    }
    return root;
}

test "memoized sibling positions match a rescanning reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for (0..16) |seed| {
        const root = try buildMixedTree(arena.allocator(), seed + 1);
        try checkPositionsAgainstReference(root);
    }
}

test "position memo is invalidated by structural changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const parent = try gpa.create(Node);
    parent.* = .{ .node_type = .element, .data = "ul" };

    var kids: [5]*Node = undefined;
    for (&kids) |*slot| {
        slot.* = try gpa.create(Node);
        slot.*.* = .{ .node_type = .element, .data = "li" };
        tree.appendChild(parent, slot.*);
    }

    // Warm the memo on the last child.
    try std.testing.expectEqual(@as(?i32, 5), positionFor(kids[4], false, null));

    // Insert at the front: every cached position is now wrong by one.
    const inserted = try gpa.create(Node);
    inserted.* = .{ .node_type = .element, .data = "li" };
    tree.insertBefore(parent, inserted, kids[0]);

    try std.testing.expectEqual(@as(?i32, 6), positionFor(kids[4], false, null));
    try std.testing.expectEqual(@as(?i32, 1), positionFor(inserted, false, null));
    try checkPositionsAgainstReference(parent);

    // Removal invalidates too.
    tree.removeChild(parent, inserted);
    try std.testing.expectEqual(@as(?i32, 5), positionFor(kids[4], false, null));
    try checkPositionsAgainstReference(parent);
}

test "positions are correct when siblings are visited out of order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const parent = try gpa.create(Node);
    parent.* = .{ .node_type = .element, .data = "ul" };

    var kids: [8]*Node = undefined;
    for (&kids, 0..) |*slot, i| {
        slot.* = try gpa.create(Node);
        slot.*.* = .{ .node_type = .element, .data = if (i % 2 == 0) "li" else "p" };
        tree.appendChild(parent, slot.*);
    }

    // Backward, then a stride, then forward: none of these are the order the
    // memo is optimized for, so each must fall back to a full count.
    var i: usize = kids.len;
    while (i > 0) {
        i -= 1;
        try std.testing.expectEqual(referencePosition(kids[i], false, null), positionFor(kids[i], false, null));
    }
    for ([_]usize{ 0, 3, 6, 1, 7, 2 }) |idx| {
        try std.testing.expectEqual(referencePosition(kids[idx], true, null), positionFor(kids[idx], true, null));
        try std.testing.expectEqual(
            referencePosition(kids[idx], false, kids[idx].data),
            positionFor(kids[idx], false, kids[idx].data),
        );
    }
}
