const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("dom/node.zig");
const Node = node_mod.Node;
const NodeType = node_mod.NodeType;
const Attribute = node_mod.Attribute;
const tree = @import("dom/tree.zig");
const html_parser = @import("dom/parser.zig");
const html_render = @import("dom/render.zig");
const css_parser = @import("css/parser.zig");
const css_matcher = @import("css/matcher.zig");
const Selector = @import("css/selector.zig").Selector;
const Matcher = css_matcher.Matcher;
const Document = @import("document.zig").Document;

const max_int = std.math.maxInt(usize);

pub const Selection = struct {
    nodes: []*Node,
    document: *Document,
    prev_sel: ?*const Selection = null,

    pub fn initSingle(node: *Node, doc: *Document) Selection {
        const nodes_buf = doc.allocator().alloc(*Node, 1) catch return .{
            .nodes = &.{},
            .document = doc,
        };
        nodes_buf[0] = node;
        return .{ .nodes = nodes_buf, .document = doc };
    }

    pub fn initEmpty(doc: *Document) Selection {
        return .{ .nodes = &.{}, .document = doc };
    }

    pub fn initFromSlice(nodes: []*Node, doc: *Document) Selection {
        return .{ .nodes = nodes, .document = doc };
    }

    // Traversal.

    /// Find descendants matching a CSS selector string.
    pub fn find(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.findMatcher(m);
    }

    /// Find descendants matching a compiled Matcher.
    pub fn findMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        return self.pushStack(findWithMatcher(alloc, self.nodes, m) catch &.{});
    }

    /// Find descendants matching nodes from another Selection.
    pub fn findSelection(self: Selection, sel: Selection) Selection {
        return self.findNodes(sel.nodes);
    }

    /// Find descendants matching specific nodes.
    pub fn findNodes(self: Selection, target_nodes: []*Node) Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        for (target_nodes) |target| {
            if (sliceContains(self.nodes, target)) {
                result.append(alloc, target) catch {};
            }
        }
        return self.pushStack(result.toOwnedSlice(alloc) catch &.{});
    }

    /// Get child elements.
    pub fn children(self: Selection) Selection {
        return self.pushStack(getChildrenNodes(self.document.allocator(), self.nodes, .all));
    }

    /// Get child elements matching a CSS selector.
    pub fn childrenFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.childrenMatcher(m);
    }

    /// Get child elements matching a Matcher.
    pub fn childrenMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        const raw = getChildrenNodes(alloc, self.nodes, .all);
        return self.filterAndPush(raw, m);
    }

    /// Get all children including text and comment nodes.
    pub fn contents(self: Selection) Selection {
        return self.pushStack(getChildrenNodes(self.document.allocator(), self.nodes, .all_including_non_elements));
    }

    /// Get contents filtered by selector. Since selectors only act on elements,
    /// this is equivalent to childrenFiltered when selector is non-empty.
    pub fn contentsFiltered(self: Selection, selector: []const u8) !Selection {
        if (selector.len == 0) return self.contents();
        return self.childrenFiltered(selector);
    }

    /// Get parent of each element.
    pub fn parent(self: Selection) Selection {
        return self.pushStack(getParentNodes(self.document.allocator(), self.nodes));
    }

    /// Get parent of each element, filtered by selector.
    pub fn parentFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.parentMatcher(m);
    }

    /// Get parent filtered by Matcher.
    pub fn parentMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(getParentNodes(alloc, self.nodes), m);
    }

    /// Get all ancestors.
    pub fn parents(self: Selection) Selection {
        return self.pushStack(getParentsNodes(self.document.allocator(), self.nodes, null, null));
    }

    /// Get all ancestors filtered by selector.
    pub fn parentsFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.parentsMatcher(m);
    }

    /// Get all ancestors filtered by Matcher.
    pub fn parentsMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(getParentsNodes(alloc, self.nodes, null, null), m);
    }

    pub const UntilOpts = struct {
        until: ?Matcher = null,
        until_nodes: ?[]*Node = null,
        filter: ?Matcher = null,
    };

    /// Get ancestors up to (not including) the element matching options.
    pub fn parentsUntil(self: Selection, opts: UntilOpts) Selection {
        const alloc = self.document.allocator();
        const raw = getParentsNodes(alloc, self.nodes, opts.until, opts.until_nodes);
        if (opts.filter) |f| {
            return self.filterAndPush(raw, f);
        }
        return self.pushStack(raw);
    }

    /// Get first ancestor matching the selector, testing the element itself first.
    pub fn closest(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.closestMatcher(m);
    }

    /// Get first ancestor matching the Matcher.
    pub fn closestMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        var seen = std.AutoHashMap(*Node, void).init(alloc);
        for (self.nodes) |n| {
            var cur: ?*Node = n;
            while (cur) |c| {
                if (c.node_type == .element and m.match(c)) {
                    if (!seen.contains(c)) {
                        seen.put(c, {}) catch {};
                        result.append(alloc, c) catch {};
                    }
                    break;
                }
                cur = c.parent;
            }
        }
        return self.pushStack(result.toOwnedSlice(alloc) catch &.{});
    }

    /// Get first ancestor matching one of the given nodes.
    pub fn closestNodes(self: Selection, target_nodes: []*Node) Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        var seen = std.AutoHashMap(*Node, void).init(alloc);
        for (self.nodes) |n| {
            var cur: ?*Node = n;
            while (cur) |c| {
                if (isInSlice(target_nodes, c)) {
                    if (!seen.contains(c)) {
                        seen.put(c, {}) catch {};
                        result.append(alloc, c) catch {};
                    }
                    break;
                }
                cur = c.parent;
            }
        }
        return self.pushStack(result.toOwnedSlice(alloc) catch &.{});
    }

    /// Get first ancestor matching a node in the given Selection.
    pub fn closestSelection(self: Selection, sel: Selection) Selection {
        return self.closestNodes(sel.nodes);
    }

    /// Get siblings of each element (excluding the element itself).
    pub fn siblings(self: Selection) Selection {
        return self.pushStack(getSiblingNodes(self.document.allocator(), self.nodes, .all, null, null));
    }

    /// Get siblings filtered by CSS selector.
    pub fn siblingsFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.siblingsMatcher(m);
    }

    /// Get siblings filtered by Matcher.
    pub fn siblingsMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(getSiblingNodes(alloc, self.nodes, .all, null, null), m);
    }

    /// Get immediately following sibling element.
    pub fn next(self: Selection) Selection {
        return self.pushStack(getSiblingNodes(self.document.allocator(), self.nodes, .next, null, null));
    }

    /// Get next sibling filtered by selector.
    pub fn nextFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.nextMatcher(m);
    }

    /// Get next sibling filtered by Matcher.
    pub fn nextMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(getSiblingNodes(alloc, self.nodes, .next, null, null), m);
    }

    /// Get all following siblings.
    pub fn nextAll(self: Selection) Selection {
        return self.pushStack(getSiblingNodes(self.document.allocator(), self.nodes, .next_all, null, null));
    }

    /// Get all following siblings filtered by selector.
    pub fn nextAllFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.nextAllMatcher(m);
    }

    /// Get all following siblings filtered by Matcher.
    pub fn nextAllMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(getSiblingNodes(alloc, self.nodes, .next_all, null, null), m);
    }

    /// Get all following siblings until a matcher/nodes boundary.
    pub fn nextUntil(self: Selection, opts: UntilOpts) Selection {
        const alloc = self.document.allocator();
        const raw = getSiblingNodes(alloc, self.nodes, .next_until, opts.until, opts.until_nodes);
        if (opts.filter) |f| return self.filterAndPush(raw, f);
        return self.pushStack(raw);
    }

    /// Get immediately preceding sibling element.
    pub fn prev(self: Selection) Selection {
        return self.pushStack(getSiblingNodes(self.document.allocator(), self.nodes, .prev, null, null));
    }

    /// Get previous sibling filtered by selector.
    pub fn prevFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.prevMatcher(m);
    }

    /// Get previous sibling filtered by Matcher.
    pub fn prevMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(getSiblingNodes(alloc, self.nodes, .prev, null, null), m);
    }

    /// Get all preceding siblings.
    pub fn prevAll(self: Selection) Selection {
        return self.pushStack(getSiblingNodes(self.document.allocator(), self.nodes, .prev_all, null, null));
    }

    /// Get all preceding siblings filtered by selector.
    pub fn prevAllFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.prevAllMatcher(m);
    }

    /// Get all preceding siblings filtered by Matcher.
    pub fn prevAllMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(getSiblingNodes(alloc, self.nodes, .prev_all, null, null), m);
    }

    /// Get all preceding siblings until a matcher/nodes boundary.
    pub fn prevUntil(self: Selection, opts: UntilOpts) Selection {
        const alloc = self.document.allocator();
        const raw = getSiblingNodes(alloc, self.nodes, .prev_until, opts.until, opts.until_nodes);
        if (opts.filter) |f| return self.filterAndPush(raw, f);
        return self.pushStack(raw);
    }

    // Filtering.

    /// Filter to elements matching the CSS selector.
    pub fn filter(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.filterMatcher(m);
    }

    /// Filter to elements matching a Matcher.
    pub fn filterMatcher(self: Selection, m: Matcher) Selection {
        return self.pushStack(winnow(self, m, true));
    }

    /// Filter using a callback function.
    pub fn filterFn(self: Selection, f: *const fn (usize, Selection) bool) Selection {
        return self.pushStack(winnowFn(self, f, true));
    }

    /// Filter to elements in the given node slice.
    pub fn filterNodes(self: Selection, target_nodes: []*Node) Selection {
        return self.pushStack(winnowNodes(self, target_nodes, true));
    }

    /// Filter to elements in the given Selection.
    pub fn filterSelection(self: Selection, sel: Selection) Selection {
        return self.filterNodes(sel.nodes);
    }

    /// Remove elements matching the CSS selector.
    pub fn not(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.notMatcher(m);
    }

    /// Remove elements matching a Matcher.
    pub fn notMatcher(self: Selection, m: Matcher) Selection {
        return self.pushStack(winnow(self, m, false));
    }

    /// Remove elements using a callback function.
    pub fn notFn(self: Selection, f: *const fn (usize, Selection) bool) Selection {
        return self.pushStack(winnowFn(self, f, false));
    }

    /// Remove elements matching specific nodes.
    pub fn notNodes(self: Selection, target_nodes: []*Node) Selection {
        return self.pushStack(winnowNodes(self, target_nodes, false));
    }

    /// Remove elements matching a Selection.
    pub fn notSelection(self: Selection, sel: Selection) Selection {
        return self.notNodes(sel.nodes);
    }

    /// Reduce to elements that have a descendant matching the selector.
    pub fn has(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.hasMatcher(m);
    }

    /// Reduce to elements that have a descendant matching a Matcher.
    pub fn hasMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        for (self.nodes) |n| {
            if (hasDescendantMatch(n, m)) {
                result.append(alloc, n) catch {};
            }
        }
        return self.pushStack(result.toOwnedSlice(alloc) catch &.{});
    }

    /// Reduce to elements that have a descendant matching given nodes.
    pub fn hasNodes(self: Selection, target_nodes: []*Node) Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        for (self.nodes) |n| {
            for (target_nodes) |target| {
                if (nodeContains(n, target)) {
                    result.append(alloc, n) catch {};
                    break;
                }
            }
        }
        return self.pushStack(result.toOwnedSlice(alloc) catch &.{});
    }

    /// Reduce to elements that have a descendant in the given Selection.
    pub fn hasSelection(self: Selection, sel: Selection) Selection {
        return self.hasNodes(sel.nodes);
    }

    /// Alias for filterSelection.
    pub fn intersection(self: Selection, sel: Selection) Selection {
        return self.filterSelection(sel);
    }

    /// Return to the previous selection in the chain.
    pub fn end(self: Selection) Selection {
        if (self.prev_sel) |p| return p.*;
        return Selection.initEmpty(self.document);
    }

    // Query.

    /// Check if any element matches the CSS selector.
    pub fn is(self: Selection, selector: []const u8) bool {
        const alloc = self.document.allocator();
        const parsed = css_parser.parseSelector(alloc, selector) catch return false;
        const m = Matcher.init(alloc, parsed);
        return self.isMatcher(m);
    }

    /// Check if any element matches a Matcher.
    pub fn isMatcher(self: Selection, m: Matcher) bool {
        for (self.nodes) |n| {
            if (m.match(n)) return true;
        }
        return false;
    }

    /// Check if any element matches using a callback.
    pub fn isFn(self: Selection, f: *const fn (usize, Selection) bool) bool {
        for (self.nodes, 0..) |n, i| {
            if (f(i, Selection.initSingle(n, self.document))) return true;
        }
        return false;
    }

    /// Check if any element matches a Selection.
    pub fn isSelection(self: Selection, sel: Selection) bool {
        return self.filterSelection(sel).len() > 0;
    }

    /// Check if any element matches specific nodes.
    pub fn isNodes(self: Selection, target_nodes: []*Node) bool {
        return self.filterNodes(target_nodes).len() > 0;
    }

    /// Check if `target` is a descendant of any node in this selection.
    /// Not inclusive (if target is in the selection itself, returns false).
    pub fn containsNode(self: Selection, target: *const Node) bool {
        return sliceContains(self.nodes, target);
    }

    // Array/Positional.

    /// First element.
    pub fn first(self: Selection) Selection {
        return self.eq(0);
    }

    /// Last element.
    pub fn last(self: Selection) Selection {
        if (self.nodes.len == 0) return Selection.initEmpty(self.document);
        return self.eqPositive(self.nodes.len - 1);
    }

    /// Element at the given position. Negative indices count from the end.
    pub fn eq(self: Selection, pos: i64) Selection {
        var idx = pos;
        if (idx < 0) idx += @as(i64, @intCast(self.nodes.len));
        if (idx < 0 or idx >= @as(i64, @intCast(self.nodes.len))) {
            return Selection.initEmpty(self.document);
        }
        return self.eqPositive(@intCast(idx));
    }

    fn eqPositive(self: Selection, pos: usize) Selection {
        return self.sliceRange(pos, pos + 1);
    }

    /// Slice of elements [start..end_idx).
    pub fn sliceRange(self: Selection, start: usize, end_idx: usize) Selection {
        const s = @min(start, self.nodes.len);
        const e = @min(end_idx, self.nodes.len);
        if (s >= e) return Selection.initEmpty(self.document);
        const alloc = self.document.allocator();
        const new_nodes = alloc.alloc(*Node, e - s) catch return Selection.initEmpty(self.document);
        @memcpy(new_nodes, self.nodes[s..e]);
        return self.pushStack(new_nodes);
    }

    /// Get the underlying node at the given position. Negative indices count from end.
    pub fn get(self: Selection, pos: i64) ?*Node {
        var idx = pos;
        if (idx < 0) idx += @as(i64, @intCast(self.nodes.len));
        if (idx < 0 or idx >= @as(i64, @intCast(self.nodes.len))) return null;
        return self.nodes[@intCast(idx)];
    }

    /// Position of first element relative to its siblings.
    pub fn index(self: Selection) ?usize {
        if (self.nodes.len == 0) return null;
        return self.prevAll().len();
    }

    /// Position of first element relative to elements matching selector.
    pub fn indexOfSelector(self: Selection, selector: []const u8) !?usize {
        if (self.nodes.len == 0) return null;
        const doc_sel = try self.document.find(selector);
        return indexInSlice(doc_sel.nodes, self.nodes[0]);
    }

    /// Position of first element relative to elements matched by Matcher.
    pub fn indexOfMatcher(self: Selection, m: Matcher) ?usize {
        if (self.nodes.len == 0) return null;
        const doc_sel = self.document.select().findMatcher(m);
        return indexInSlice(doc_sel.nodes, self.nodes[0]);
    }

    /// Position of a node within this Selection.
    pub fn indexOfNode(self: Selection, node: *Node) ?usize {
        return indexInSlice(self.nodes, node);
    }

    /// Position of first node in `sel` within this Selection.
    pub fn indexOfSelection(self: Selection, sel: Selection) ?usize {
        if (sel.nodes.len == 0) return null;
        return indexInSlice(self.nodes, sel.nodes[0]);
    }

    /// Number of elements.
    pub fn len(self: Selection) usize {
        return self.nodes.len;
    }

    /// Alias for len.
    pub fn length(self: Selection) usize {
        return self.len();
    }

    // Iteration.

    /// Call `f` for each element. The function receives the index and a
    /// single-element Selection.
    pub fn each(self: Selection, f: *const fn (usize, Selection) void) void {
        for (self.nodes, 0..) |n, i| {
            f(i, Selection.initSingle(n, self.document));
        }
    }

    /// Like each but the callback can return false to break.
    pub fn eachWithBreak(self: Selection, f: *const fn (usize, Selection) bool) void {
        for (self.nodes, 0..) |n, i| {
            if (!f(i, Selection.initSingle(n, self.document))) return;
        }
    }

    /// Iterator over elements as single-element Selections.
    pub fn iterator(self: Selection) Iterator {
        return .{ .sel = self, .pos = 0 };
    }

    pub const Iterator = struct {
        sel: Selection,
        pos: usize,

        pub fn next(self: *Iterator) ?Selection {
            if (self.pos >= self.sel.nodes.len) return null;
            const n = self.sel.nodes[self.pos];
            self.pos += 1;
            return Selection.initSingle(n, self.sel.document);
        }
    };

    // Properties.

    /// Get attribute value from the first element.
    pub fn attr(self: Selection, name: []const u8) ?[]const u8 {
        if (self.nodes.len == 0) return null;
        return self.nodes[0].getAttr(name);
    }

    /// Get attribute value with a default.
    pub fn attrOr(self: Selection, name: []const u8, default: []const u8) []const u8 {
        return self.attr(name) orelse default;
    }

    /// Set an attribute on all elements.
    pub fn setAttr(self: Selection, name: []const u8, val: []const u8) void {
        const alloc = self.document.allocator();
        for (self.nodes) |n| {
            setNodeAttr(alloc, n, name, val);
        }
    }

    /// Remove a named attribute from all elements.
    pub fn removeAttr(self: Selection, name: []const u8) void {
        for (self.nodes) |n| {
            removeNodeAttr(n, name);
        }
    }

    /// Add CSS class(es) to all elements. Multiple classes separated by space.
    pub fn addClass(self: Selection, classes: []const u8) void {
        const alloc = self.document.allocator();
        var it = std.mem.tokenizeAny(u8, classes, " \t\n\r");
        while (it.next()) |cls| {
            for (self.nodes) |n| {
                if (n.node_type != .element) continue;
                const current = n.getAttr("class") orelse "";
                if (!hasClassInStr(current, cls)) {
                    const new_val = if (current.len > 0)
                        std.fmt.allocPrint(alloc, "{s} {s}", .{ current, cls }) catch continue
                    else
                        cls;
                    setNodeAttr(alloc, n, "class", new_val);
                }
            }
        }
    }

    /// Check if any element has the given class.
    pub fn hasClass(self: Selection, class: []const u8) bool {
        for (self.nodes) |n| {
            const class_attr = n.getAttr("class") orelse continue;
            if (hasClassInStr(class_attr, class)) return true;
        }
        return false;
    }

    /// Remove CSS class(es) from all elements.
    pub fn removeClass(self: Selection, classes: []const u8) void {
        const alloc = self.document.allocator();
        if (classes.len == 0) {
            for (self.nodes) |n| {
                removeNodeAttr(n, "class");
            }
            return;
        }
        for (self.nodes) |n| {
            if (n.node_type != .element) continue;
            const current = n.getAttr("class") orelse continue;
            var result: std.ArrayList(u8) = .empty;
            var cls_it = std.mem.tokenizeAny(u8, current, " \t\n\r");
            var first_word = true;
            while (cls_it.next()) |word| {
                var should_remove = false;
                var rem_it = std.mem.tokenizeAny(u8, classes, " \t\n\r");
                while (rem_it.next()) |rem| {
                    if (std.mem.eql(u8, word, rem)) {
                        should_remove = true;
                        break;
                    }
                }
                if (!should_remove) {
                    if (!first_word) result.append(alloc, ' ') catch {};
                    result.appendSlice(alloc, word) catch {};
                    first_word = false;
                }
            }
            const new_val = result.toOwnedSlice(alloc) catch "";
            if (new_val.len == 0) {
                removeNodeAttr(n, "class");
            } else {
                setNodeAttr(alloc, n, "class", new_val);
            }
        }
    }

    /// Toggle CSS class(es) on all elements.
    pub fn toggleClass(self: Selection, classes: []const u8) void {
        const alloc = self.document.allocator();
        var it = std.mem.tokenizeAny(u8, classes, " \t\n\r");
        while (it.next()) |cls| {
            for (self.nodes) |n| {
                if (n.node_type != .element) continue;
                const current = n.getAttr("class") orelse "";
                if (hasClassInStr(current, cls)) {
                    // Remove it.
                    var result: std.ArrayList(u8) = .empty;
                    var tok = std.mem.tokenizeAny(u8, current, " \t\n\r");
                    var first_word = true;
                    while (tok.next()) |word| {
                        if (!std.mem.eql(u8, word, cls)) {
                            if (!first_word) result.append(alloc, ' ') catch {};
                            result.appendSlice(alloc, word) catch {};
                            first_word = false;
                        }
                    }
                    const new_val = result.toOwnedSlice(alloc) catch "";
                    if (new_val.len == 0) {
                        removeNodeAttr(n, "class");
                    } else {
                        setNodeAttr(alloc, n, "class", new_val);
                    }
                } else {
                    // Add it.
                    const new_val = if (current.len > 0)
                        std.fmt.allocPrint(alloc, "{s} {s}", .{ current, cls }) catch continue
                    else
                        cls;
                    setNodeAttr(alloc, n, "class", new_val);
                }
            }
        }
    }

    /// Get inner HTML of the first element.
    pub fn html(self: Selection) ![]const u8 {
        if (self.nodes.len == 0) return "";
        const alloc = self.document.allocator();
        return html_render.renderChildrenToString(alloc, self.nodes[0]);
    }

    /// Get combined text content of all elements.
    pub fn text(self: Selection) ![]const u8 {
        const alloc = self.document.allocator();
        var buf: std.ArrayList(u8) = .empty;
        for (self.nodes) |n| {
            collectText(alloc, n, &buf);
        }
        return buf.toOwnedSlice(alloc);
    }

    // Manipulation.

    /// Insert nodes after each element in the selection.
    pub fn afterNodes(self: Selection, ns: []*Node) void {
        const alloc = self.document.allocator();
        const lasti = if (self.nodes.len > 0) self.nodes.len - 1 else return;
        for (self.nodes, 0..) |sn, i| {
            if (sn.parent == null) continue;
            // Reverse iterate to maintain order.
            var j: usize = ns.len;
            while (j > 0) {
                j -= 1;
                const n = if (i != lasti)
                    tree.cloneNode(alloc, ns[j]) catch continue
                else blk: {
                    tree.detach(ns[j]);
                    break :blk ns[j];
                };
                tree.insertBefore(sn.parent.?, n, sn.next_sibling);
            }
        }
    }

    /// Insert HTML after each element.
    pub fn afterHtml(self: Selection, html_str: []const u8) void {
        const alloc = self.document.allocator();
        for (self.nodes) |n| {
            if (n.parent == null) continue;
            const nodes = html_parser.parseFragment(alloc, html_str, n.parent.?) catch continue;
            const next_sib = n.next_sibling;
            for (nodes) |new_node| {
                tree.insertBefore(n.parent.?, new_node, next_sib);
            }
        }
    }

    /// Insert nodes before each element.
    pub fn beforeNodes(self: Selection, ns: []*Node) void {
        const alloc = self.document.allocator();
        const lasti = if (self.nodes.len > 0) self.nodes.len - 1 else return;
        for (self.nodes, 0..) |sn, i| {
            if (sn.parent == null) continue;
            for (ns) |n| {
                const node = if (i != lasti)
                    tree.cloneNode(alloc, n) catch continue
                else blk: {
                    tree.detach(n);
                    break :blk n;
                };
                tree.insertBefore(sn.parent.?, node, sn);
            }
        }
    }

    /// Insert HTML before each element.
    pub fn beforeHtml(self: Selection, html_str: []const u8) void {
        const alloc = self.document.allocator();
        for (self.nodes) |n| {
            if (n.parent == null) continue;
            const nodes = html_parser.parseFragment(alloc, html_str, n.parent.?) catch continue;
            for (nodes) |new_node| {
                tree.insertBefore(n.parent.?, new_node, n);
            }
        }
    }

    /// Append nodes as children of each element.
    pub fn appendNodes(self: Selection, ns: []*Node) void {
        const alloc = self.document.allocator();
        const lasti = if (self.nodes.len > 0) self.nodes.len - 1 else return;
        for (self.nodes, 0..) |sn, i| {
            for (ns) |n| {
                const node = if (i != lasti)
                    tree.cloneNode(alloc, n) catch continue
                else blk: {
                    tree.detach(n);
                    break :blk n;
                };
                tree.appendChild(sn, node);
            }
        }
    }

    /// Append parsed HTML as children of each element.
    pub fn appendHtml(self: Selection, html_str: []const u8) void {
        const alloc = self.document.allocator();
        for (self.nodes) |n| {
            if (n.node_type != .element) continue;
            const nodes = html_parser.parseFragment(alloc, html_str, n) catch continue;
            for (nodes) |new_node| {
                tree.appendChild(n, new_node);
            }
        }
    }

    /// Prepend nodes as first children of each element.
    pub fn prependNodes(self: Selection, ns: []*Node) void {
        const alloc = self.document.allocator();
        const lasti = if (self.nodes.len > 0) self.nodes.len - 1 else return;
        for (self.nodes, 0..) |sn, i| {
            const first_child = sn.first_child;
            // Reverse to maintain order.
            var j: usize = ns.len;
            while (j > 0) {
                j -= 1;
                const node = if (i != lasti)
                    tree.cloneNode(alloc, ns[j]) catch continue
                else blk: {
                    tree.detach(ns[j]);
                    break :blk ns[j];
                };
                tree.insertBefore(sn, node, first_child);
            }
        }
    }

    /// Prepend parsed HTML.
    pub fn prependHtml(self: Selection, html_str: []const u8) void {
        const alloc = self.document.allocator();
        for (self.nodes) |n| {
            if (n.node_type != .element) continue;
            const first_child = n.first_child;
            const nodes = html_parser.parseFragment(alloc, html_str, n) catch continue;
            // Insert in reverse to maintain order before first_child.
            var k: usize = nodes.len;
            while (k > 0) {
                k -= 1;
                tree.insertBefore(n, nodes[k], first_child);
            }
        }
    }

    /// Remove all elements from the document.
    pub fn remove(self: Selection) Selection {
        for (self.nodes) |n| {
            tree.detach(n);
        }
        return self;
    }

    /// Remove elements matching the CSS selector from this selection.
    pub fn removeFiltered(self: Selection, selector: []const u8) !Selection {
        return (try self.filter(selector)).remove();
    }

    /// Remove elements matching the Matcher.
    pub fn removeMatcher(self: Selection, m: Matcher) Selection {
        return self.filterMatcher(m).remove();
    }

    /// Replace each element with the given nodes.
    pub fn replaceWithNodes(self: Selection, ns: []*Node) Selection {
        self.afterNodes(ns);
        return self.remove();
    }

    /// Replace with parsed HTML.
    pub fn replaceWithHtml(self: Selection, html_str: []const u8) Selection {
        self.afterHtml(html_str);
        return self.remove();
    }

    /// Deep-clone the matched elements.
    pub fn cloneSel(self: Selection) Selection {
        const alloc = self.document.allocator();
        const cloned = tree.cloneNodes(alloc, self.nodes) catch return Selection.initEmpty(self.document);
        return Selection.initFromSlice(cloned, self.document);
    }

    /// Remove all children from each element, returning removed children.
    pub fn empty(self: Selection) Selection {
        const alloc = self.document.allocator();
        var removed: std.ArrayList(*Node) = .empty;
        for (self.nodes) |n| {
            while (n.first_child) |child| {
                tree.removeChild(n, child);
                removed.append(alloc, child) catch {};
            }
        }
        return self.pushStack(removed.toOwnedSlice(alloc) catch &.{});
    }

    /// Set inner HTML of each element.
    pub fn setHtml(self: Selection, html_str: []const u8) void {
        for (self.nodes) |n| {
            while (n.first_child) |child| {
                tree.removeChild(n, child);
            }
        }
        self.appendHtml(html_str);
    }

    /// Set text content (HTML-escaped).
    pub fn setText(self: Selection, text_str: []const u8) void {
        const alloc = self.document.allocator();
        const escaped = html_render.escapeString(alloc, text_str) catch return;
        self.setHtml(escaped);
    }

    /// Remove the parent of each element, leaving matched elements in place.
    pub fn unwrap(self: Selection) void {
        const parent_sel = self.parent();
        for (parent_sel.nodes) |p| {
            if (std.mem.eql(u8, p.data, "body")) continue;
            const grand = p.parent orelse continue;
            // Move all children of p before p, then remove p.
            while (p.first_child) |child| {
                tree.removeChild(p, child);
                tree.insertBefore(grand, child, p);
            }
            tree.removeChild(grand, p);
        }
    }

    /// Wrap each element inside a clone of the first matched wrapper node.
    pub fn wrapNode(self: Selection, wrapper: *Node) void {
        const alloc = self.document.allocator();
        for (self.nodes) |n| {
            const wrap = tree.cloneNode(alloc, wrapper) catch continue;
            if (n.parent) |p| {
                tree.insertBefore(p, wrap, n);
                tree.removeChild(p, n);
            }
            // Find deepest first-child element.
            var deepest = wrap;
            while (tree.getFirstChildElement(deepest)) |child_el| {
                deepest = child_el;
            }
            tree.appendChild(deepest, n);
        }
    }

    /// Wrap each element inside the first element matched by HTML string.
    pub fn wrapHtml(self: Selection, html_str: []const u8) void {
        const alloc = self.document.allocator();
        for (self.nodes) |n| {
            var context_node: *Node = undefined;
            if (n.parent) |p| {
                context_node = p;
            } else {
                context_node = alloc.create(Node) catch continue;
                context_node.* = .{ .node_type = .element, .data = "div" };
            }
            const parsed = html_parser.parseFragment(alloc, html_str, context_node) catch continue;
            if (parsed.len == 0) continue;
            const wrap = parsed[0];
            if (n.parent) |p| {
                tree.insertBefore(p, wrap, n);
                tree.removeChild(p, n);
            }
            var deepest = wrap;
            while (tree.getFirstChildElement(deepest)) |child_el| {
                deepest = child_el;
            }
            tree.appendChild(deepest, n);
        }
    }

    /// Wrap all elements together inside a single clone of the wrapper node.
    pub fn wrapAllNode(self: Selection, wrapper: *Node) void {
        if (self.nodes.len == 0) return;
        const alloc = self.document.allocator();
        const wrap = tree.cloneNode(alloc, wrapper) catch return;
        const first_node = self.nodes[0];
        if (first_node.parent) |p| {
            tree.insertBefore(p, wrap, first_node);
        }
        var deepest = wrap;
        while (tree.getFirstChildElement(deepest)) |child_el| {
            deepest = child_el;
        }
        for (self.nodes) |n| {
            tree.detach(n);
            tree.appendChild(deepest, n);
        }
    }

    /// Wrap content of each element.
    pub fn wrapInnerNode(self: Selection, wrapper: *Node) void {
        const alloc = self.document.allocator();
        for (self.nodes) |n| {
            const wrap = tree.cloneNode(alloc, wrapper) catch continue;
            var deepest = wrap;
            while (tree.getFirstChildElement(deepest)) |child_el| {
                deepest = child_el;
            }
            // Move children of n into deepest.
            while (n.first_child) |child| {
                tree.removeChild(n, child);
                tree.appendChild(deepest, child);
            }
            tree.appendChild(n, wrap);
        }
    }

    /// Add nodes matching CSS selector to this selection.
    pub fn add(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.addMatcher(m);
    }

    /// Add nodes matching Matcher to this selection.
    pub fn addMatcher(self: Selection, m: Matcher) Selection {
        const alloc = self.document.allocator();
        const root_slice = alloc.alloc(*Node, 1) catch return self;
        root_slice[0] = self.document.root_node;
        const found = findWithMatcher(alloc, root_slice, m) catch return self;
        return self.addNodes(found);
    }

    /// Add a Selection's nodes to this selection.
    pub fn addSelection(self: Selection, sel: Selection) Selection {
        return self.addNodes(sel.nodes);
    }

    /// Add specific nodes to this selection.
    pub fn addNodes(self: Selection, extra_nodes: []*Node) Selection {
        const alloc = self.document.allocator();
        const merged = appendWithoutDuplicates(alloc, self.nodes, extra_nodes);
        return self.pushStack(merged);
    }

    /// Alias for addSelection.
    pub fn @"union"(self: Selection, sel: Selection) Selection {
        return self.addSelection(sel);
    }

    /// Add back the previous selection.
    pub fn addBack(self: Selection) Selection {
        if (self.prev_sel) |p| return self.addSelection(p.*);
        return self;
    }

    /// Add back the previous selection filtered by CSS selector.
    pub fn addBackFiltered(self: Selection, selector: []const u8) !Selection {
        if (self.prev_sel) |p| return self.addSelection(try p.filter(selector));
        return self;
    }

    // Internal helpers.

    fn pushStack(self: Selection, new_nodes: []*Node) Selection {
        const alloc = self.document.allocator();
        const saved = alloc.create(Selection) catch return Selection{
            .nodes = new_nodes,
            .document = self.document,
        };
        saved.* = self;
        return Selection{
            .nodes = new_nodes,
            .document = self.document,
            .prev_sel = saved,
        };
    }

    fn filterAndPush(self: Selection, raw_nodes: []*Node, m: Matcher) Selection {
        const filtered = m.filter(raw_nodes) catch return self.pushStack(&.{});
        return self.pushStack(filtered);
    }
};

/// Render the outer HTML of the first element.
pub fn outerHtml(sel: Selection) ![]const u8 {
    if (sel.nodes.len == 0) return "";
    return html_render.renderToString(sel.document.allocator(), sel.nodes[0]);
}

/// Get the node name of the first element.
pub fn nodeName(sel: Selection) []const u8 {
    if (sel.nodes.len == 0) return "";
    const n = sel.nodes[0];
    return switch (n.node_type) {
        .element, .doctype => n.data,
        .text => "#text",
        .comment => "#comment",
        .document => "#document",
    };
}

fn findWithMatcher(alloc: Allocator, nodes: []*Node, m: Matcher) ![]*Node {
    var result: std.ArrayList(*Node) = .empty;
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (nodes) |n| {
        var child = n.first_child;
        while (child) |c| {
            if (c.node_type == .element) {
                try collectMatchesDedup(alloc, m, c, &result, &seen);
            }
            child = c.next_sibling;
        }
    }
    return result.toOwnedSlice(alloc);
}

fn collectMatchesDedup(alloc: Allocator, m: Matcher, node: *Node, result: *std.ArrayList(*Node), seen: *std.AutoHashMap(*Node, void)) !void {
    if (m.match(node)) {
        if (!seen.contains(node)) {
            try seen.put(node, {});
            try result.append(alloc, node);
        }
    }
    var child = node.first_child;
    while (child) |c| {
        if (c.node_type == .element) {
            try collectMatchesDedup(alloc, m, c, result, seen);
        }
        child = c.next_sibling;
    }
}

const SiblingType = enum {
    all,
    all_including_non_elements,
    next,
    next_all,
    next_until,
    prev,
    prev_all,
    prev_until,
};

fn getChildrenNodes(alloc: Allocator, nodes: []*Node, st: SiblingType) []*Node {
    var result: std.ArrayList(*Node) = .empty;
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (nodes) |n| {
        var child = n.first_child;
        while (child) |c| {
            const include = switch (st) {
                .all_including_non_elements => true,
                else => c.node_type == .element,
            };
            if (include and !seen.contains(c)) {
                seen.put(c, {}) catch {};
                result.append(alloc, c) catch {};
            }
            child = c.next_sibling;
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn getParentNodes(alloc: Allocator, nodes: []*Node) []*Node {
    var result: std.ArrayList(*Node) = .empty;
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (nodes) |n| {
        if (n.parent) |p| {
            if (p.node_type == .element and !seen.contains(p)) {
                seen.put(p, {}) catch {};
                result.append(alloc, p) catch {};
            }
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn getParentsNodes(alloc: Allocator, nodes: []*Node, until_matcher: ?Matcher, until_nodes: ?[]*Node) []*Node {
    var result: std.ArrayList(*Node) = .empty;
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (nodes) |n| {
        var p = n.parent;
        while (p) |parent| {
            if (until_matcher) |um| {
                if (um.match(parent)) break;
            }
            if (until_nodes) |un| {
                if (isInSlice(un, parent)) break;
            }
            if (parent.node_type == .element and !seen.contains(parent)) {
                seen.put(parent, {}) catch {};
                result.append(alloc, parent) catch {};
            }
            p = parent.parent;
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn getSiblingNodes(alloc: Allocator, nodes: []*Node, st: SiblingType, until_matcher: ?Matcher, until_nodes: ?[]*Node) []*Node {
    var result: std.ArrayList(*Node) = .empty;
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (nodes) |n| {
        const siblings = getNodeSiblings(alloc, n, st, until_matcher, until_nodes);
        for (siblings) |s| {
            if (!seen.contains(s)) {
                seen.put(s, {}) catch {};
                result.append(alloc, s) catch {};
            }
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn getNodeSiblings(alloc: Allocator, node: *Node, st: SiblingType, until_matcher: ?Matcher, until_nodes: ?[]*Node) []*Node {
    var result: std.ArrayList(*Node) = .empty;
    const parent = node.parent orelse return result.toOwnedSlice(alloc) catch &.{};

    switch (st) {
        .all, .all_including_non_elements => {
            var c = parent.first_child;
            while (c) |child| {
                if (child != node and child.node_type == .element) {
                    result.append(alloc, child) catch {};
                }
                c = child.next_sibling;
            }
        },
        .next => {
            var c = node.next_sibling;
            while (c) |child| {
                if (child.node_type == .element) {
                    result.append(alloc, child) catch {};
                    break;
                }
                c = child.next_sibling;
            }
        },
        .next_all => {
            var c = node.next_sibling;
            while (c) |child| {
                if (child.node_type == .element) result.append(alloc, child) catch {};
                c = child.next_sibling;
            }
        },
        .next_until => {
            var c = node.next_sibling;
            while (c) |child| {
                if (child.node_type == .element) {
                    if (matchesUntil(child, until_matcher, until_nodes)) break;
                    result.append(alloc, child) catch {};
                }
                c = child.next_sibling;
            }
        },
        .prev => {
            var c = node.prev_sibling;
            while (c) |child| {
                if (child.node_type == .element) {
                    result.append(alloc, child) catch {};
                    break;
                }
                c = child.prev_sibling;
            }
        },
        .prev_all => {
            var c = node.prev_sibling;
            while (c) |child| {
                if (child.node_type == .element) result.append(alloc, child) catch {};
                c = child.prev_sibling;
            }
        },
        .prev_until => {
            var c = node.prev_sibling;
            while (c) |child| {
                if (child.node_type == .element) {
                    if (matchesUntil(child, until_matcher, until_nodes)) break;
                    result.append(alloc, child) catch {};
                }
                c = child.prev_sibling;
            }
        },
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn matchesUntil(node: *Node, until_matcher: ?Matcher, until_nodes: ?[]*Node) bool {
    if (until_matcher) |m| {
        if (m.match(node)) return true;
    }
    if (until_nodes) |nodes| {
        if (isInSlice(nodes, node)) return true;
    }
    return false;
}

fn winnow(sel: Selection, m: Matcher, keep: bool) []*Node {
    if (keep) {
        return m.filter(sel.nodes) catch &.{};
    }
    const alloc = sel.document.allocator();
    var result: std.ArrayList(*Node) = .empty;
    for (sel.nodes) |n| {
        if (!m.match(n)) result.append(alloc, n) catch {};
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn winnowFn(sel: Selection, f: *const fn (usize, Selection) bool, keep: bool) []*Node {
    const alloc = sel.document.allocator();
    var result: std.ArrayList(*Node) = .empty;
    for (sel.nodes, 0..) |n, i| {
        const matches = f(i, Selection.initSingle(n, sel.document));
        if (matches == keep) result.append(alloc, n) catch {};
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn winnowNodes(sel: Selection, target_nodes: []*Node, keep: bool) []*Node {
    const alloc = sel.document.allocator();
    var result: std.ArrayList(*Node) = .empty;
    for (sel.nodes) |n| {
        const in_targets = isInSlice(target_nodes, n);
        if (in_targets == keep) result.append(alloc, n) catch {};
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn appendWithoutDuplicates(alloc: Allocator, target: []*Node, new_nodes: []*Node) []*Node {
    var result: std.ArrayList(*Node) = .empty;
    result.appendSlice(alloc, target) catch {};
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (target) |n| seen.put(n, {}) catch {};
    for (new_nodes) |n| {
        if (!seen.contains(n)) {
            seen.put(n, {}) catch {};
            result.append(alloc, n) catch {};
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

fn isInSlice(s: []*Node, node: *Node) bool {
    for (s) |n| {
        if (n == node) return true;
    }
    return false;
}

fn indexInSlice(s: []*Node, node: *Node) ?usize {
    for (s, 0..) |n, i| {
        if (n == node) return i;
    }
    return null;
}

fn sliceContains(container: []*Node, contained: *const Node) bool {
    for (container) |n| {
        if (nodeContains(n, contained)) return true;
    }
    return false;
}

fn nodeContains(container: *const Node, contained: *const Node) bool {
    var p = contained.parent;
    while (p) |parent| {
        if (parent == container) return true;
        p = parent.parent;
    }
    return false;
}

fn hasDescendantMatch(node: *const Node, m: Matcher) bool {
    var child = node.first_child;
    while (child) |c| {
        if (c.node_type == .element) {
            if (m.match(c)) return true;
            if (hasDescendantMatch(c, m)) return true;
        }
        child = c.next_sibling;
    }
    return false;
}

fn collectText(alloc: Allocator, node: *const Node, buf: *std.ArrayList(u8)) void {
    if (node.node_type == .text) {
        buf.appendSlice(alloc, node.data) catch {};
        return;
    }
    var child = node.first_child;
    while (child) |c| {
        collectText(alloc, c, buf);
        child = c.next_sibling;
    }
}

fn hasClassInStr(class_attr: []const u8, cls: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, class_attr, " \t\n\r");
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, cls)) return true;
    }
    return false;
}

fn setNodeAttr(alloc: Allocator, node: *Node, key: []const u8, val: []const u8) void {
    for (node.attr) |*a| {
        if (std.mem.eql(u8, a.key, key)) {
            a.val = val;
            return;
        }
    }
    // Attribute not found, need to add.
    var new_attrs = alloc.alloc(Attribute, node.attr.len + 1) catch return;
    @memcpy(new_attrs[0..node.attr.len], node.attr);
    new_attrs[node.attr.len] = .{ .key = key, .val = val };
    node.attr = new_attrs;
}

fn removeNodeAttr(node: *Node, key: []const u8) void {
    for (node.attr, 0..) |a, i| {
        if (std.mem.eql(u8, a.key, key)) {
            // Swap-remove.
            const last = node.attr.len - 1;
            if (i != last) {
                node.attr[i] = node.attr[last];
            }
            node.attr = node.attr[0..last];
            return;
        }
    }
}

test "Selection find" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>Hello</p><p>World</p></div>");
    defer doc.deinit();
    const sel = try doc.find("p");
    try std.testing.expect(sel.len() == 2);
}

test "Selection children" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><span>A</span><span>B</span></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const spans = div.children();
    try std.testing.expect(spans.len() == 2);
}

test "Selection parent" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>test</p></div>");
    defer doc.deinit();
    const p = try doc.find("p");
    const par = p.parent();
    try std.testing.expect(par.len() == 1);
    try std.testing.expectEqualStrings("div", par.nodes[0].data);
}

test "Selection attr" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<a href=\"/test\">link</a>");
    defer doc.deinit();
    const a = try doc.find("a");
    try std.testing.expectEqualStrings("/test", a.attr("href").?);
}

test "Selection text" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div>Hello <span>World</span></div>");
    defer doc.deinit();
    const div = try doc.find("div");
    const t = try div.text();
    try std.testing.expect(std.mem.indexOf(u8, t, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "World") != null);
}

test "Selection hasClass" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div class=\"foo bar\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expect(div.hasClass("foo"));
    try std.testing.expect(div.hasClass("bar"));
    try std.testing.expect(!div.hasClass("baz"));
}

test "Selection first and last" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<ul><li>1</li><li>2</li><li>3</li></ul>");
    defer doc.deinit();
    const lis = try doc.find("li");
    try std.testing.expect(lis.len() == 3);
    try std.testing.expect(lis.first().len() == 1);
    try std.testing.expect(lis.last().len() == 1);
}

test "Selection is" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div class=\"active\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expect(div.is(".active"));
    try std.testing.expect(!div.is(".inactive"));
}

test "Selection empty selection" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div></div>");
    defer doc.deinit();
    const nonexistent = try doc.find("span");
    try std.testing.expect(nonexistent.len() == 0);
    try std.testing.expect(nonexistent.attr("id") == null);
    try std.testing.expect(!nonexistent.hasClass("foo"));
}
