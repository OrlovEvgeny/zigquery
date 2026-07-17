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
const CompiledSelector = @import("css/compiled.zig").CompiledSelector;
const Document = @import("document.zig").Document;

const max_int = std.math.maxInt(usize);

pub const Selection = struct {
    nodes: []*Node,
    document: *Document,
    prev_sel: ?*const Selection = null,

    pub fn initSingle(node: *Node, doc: *Document) !Selection {
        const nodes_buf = try doc.allocator().alloc(*Node, 1);
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
    pub fn findMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        return self.pushStack(try findWithMatcher(alloc, self.nodes, m));
    }

    /// Find descendants using a reusable compiled selector.
    pub fn findCompiled(self: Selection, compiled: *const CompiledSelector) !Selection {
        return self.findMatcher(compiled.matcher(self.document.allocator()));
    }

    /// Find descendants matching nodes from another Selection.
    pub fn findSelection(self: Selection, sel: Selection) !Selection {
        return self.findNodes(sel.nodes);
    }

    /// Find descendants matching specific nodes.
    pub fn findNodes(self: Selection, target_nodes: []*Node) !Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        for (target_nodes) |target| {
            if (sliceContains(self.nodes, target)) {
                try result.append(alloc, target);
            }
        }
        return self.pushStack(try result.toOwnedSlice(alloc));
    }

    /// Get child elements.
    pub fn children(self: Selection) !Selection {
        return self.pushStack(try getChildrenNodes(self.document.allocator(), self.nodes, .all));
    }

    /// Get child elements matching a CSS selector.
    pub fn childrenFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.childrenMatcher(m);
    }

    /// Get child elements matching a Matcher.
    pub fn childrenMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        const raw = try getChildrenNodes(alloc, self.nodes, .all);
        return self.filterAndPush(raw, m);
    }

    /// Get all children including text and comment nodes.
    pub fn contents(self: Selection) !Selection {
        return self.pushStack(try getChildrenNodes(self.document.allocator(), self.nodes, .all_including_non_elements));
    }

    /// Get contents filtered by selector. Since selectors only act on elements,
    /// this is equivalent to childrenFiltered when selector is non-empty.
    pub fn contentsFiltered(self: Selection, selector: []const u8) !Selection {
        if (selector.len == 0) return self.contents();
        return self.childrenFiltered(selector);
    }

    /// Get parent of each element.
    pub fn parent(self: Selection) !Selection {
        return self.pushStack(try getParentNodes(self.document.allocator(), self.nodes));
    }

    /// Get parent of each element, filtered by selector.
    pub fn parentFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.parentMatcher(m);
    }

    /// Get parent filtered by Matcher.
    pub fn parentMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(try getParentNodes(alloc, self.nodes), m);
    }

    /// Get all ancestors.
    pub fn parents(self: Selection) !Selection {
        return self.pushStack(try getParentsNodes(self.document.allocator(), self.nodes, null, null));
    }

    /// Get all ancestors filtered by selector.
    pub fn parentsFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.parentsMatcher(m);
    }

    /// Get all ancestors filtered by Matcher.
    pub fn parentsMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(try getParentsNodes(alloc, self.nodes, null, null), m);
    }

    pub const UntilOpts = struct {
        until: ?Matcher = null,
        until_nodes: ?[]*Node = null,
        filter: ?Matcher = null,
    };

    /// Get ancestors up to (not including) the element matching options.
    pub fn parentsUntil(self: Selection, opts: UntilOpts) !Selection {
        const alloc = self.document.allocator();
        const raw = try getParentsNodes(alloc, self.nodes, opts.until, opts.until_nodes);
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
    pub fn closestMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        var seen = std.AutoHashMap(*Node, void).init(alloc);
        for (self.nodes) |n| {
            var cur: ?*Node = n;
            while (cur) |c| {
                if (c.node_type == .element and m.match(c)) {
                    if (!seen.contains(c)) {
                        try seen.put(c, {});
                        try result.append(alloc, c);
                    }
                    break;
                }
                cur = c.parent;
            }
        }
        return self.pushStack(try result.toOwnedSlice(alloc));
    }

    /// Get first ancestor matching a reusable compiled selector.
    pub fn closestCompiled(self: Selection, compiled: *const CompiledSelector) !Selection {
        return self.closestMatcher(compiled.matcher(self.document.allocator()));
    }

    /// Get first ancestor matching one of the given nodes.
    pub fn closestNodes(self: Selection, target_nodes: []*Node) !Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        var seen = std.AutoHashMap(*Node, void).init(alloc);
        for (self.nodes) |n| {
            var cur: ?*Node = n;
            while (cur) |c| {
                if (isInSlice(target_nodes, c)) {
                    if (!seen.contains(c)) {
                        try seen.put(c, {});
                        try result.append(alloc, c);
                    }
                    break;
                }
                cur = c.parent;
            }
        }
        return self.pushStack(try result.toOwnedSlice(alloc));
    }

    /// Get first ancestor matching a node in the given Selection.
    pub fn closestSelection(self: Selection, sel: Selection) !Selection {
        return self.closestNodes(sel.nodes);
    }

    /// Get siblings of each element (excluding the element itself).
    pub fn siblings(self: Selection) !Selection {
        return self.pushStack(try getSiblingNodes(self.document.allocator(), self.nodes, .all, null, null));
    }

    /// Get siblings filtered by CSS selector.
    pub fn siblingsFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.siblingsMatcher(m);
    }

    /// Get siblings filtered by Matcher.
    pub fn siblingsMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(try getSiblingNodes(alloc, self.nodes, .all, null, null), m);
    }

    /// Get immediately following sibling element.
    pub fn next(self: Selection) !Selection {
        return self.pushStack(try getSiblingNodes(self.document.allocator(), self.nodes, .next, null, null));
    }

    /// Get next sibling filtered by selector.
    pub fn nextFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.nextMatcher(m);
    }

    /// Get next sibling filtered by Matcher.
    pub fn nextMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(try getSiblingNodes(alloc, self.nodes, .next, null, null), m);
    }

    /// Get all following siblings.
    pub fn nextAll(self: Selection) !Selection {
        return self.pushStack(try getSiblingNodes(self.document.allocator(), self.nodes, .next_all, null, null));
    }

    /// Get all following siblings filtered by selector.
    pub fn nextAllFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.nextAllMatcher(m);
    }

    /// Get all following siblings filtered by Matcher.
    pub fn nextAllMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(try getSiblingNodes(alloc, self.nodes, .next_all, null, null), m);
    }

    /// Get all following siblings until a matcher/nodes boundary.
    pub fn nextUntil(self: Selection, opts: UntilOpts) !Selection {
        const alloc = self.document.allocator();
        const raw = try getSiblingNodes(alloc, self.nodes, .next_until, opts.until, opts.until_nodes);
        if (opts.filter) |f| return self.filterAndPush(raw, f);
        return self.pushStack(raw);
    }

    /// Get immediately preceding sibling element.
    pub fn prev(self: Selection) !Selection {
        return self.pushStack(try getSiblingNodes(self.document.allocator(), self.nodes, .prev, null, null));
    }

    /// Get previous sibling filtered by selector.
    pub fn prevFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.prevMatcher(m);
    }

    /// Get previous sibling filtered by Matcher.
    pub fn prevMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(try getSiblingNodes(alloc, self.nodes, .prev, null, null), m);
    }

    /// Get all preceding siblings.
    pub fn prevAll(self: Selection) !Selection {
        return self.pushStack(try getSiblingNodes(self.document.allocator(), self.nodes, .prev_all, null, null));
    }

    /// Get all preceding siblings filtered by selector.
    pub fn prevAllFiltered(self: Selection, selector: []const u8) !Selection {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
        const m = Matcher.init(alloc, parsed);
        return self.prevAllMatcher(m);
    }

    /// Get all preceding siblings filtered by Matcher.
    pub fn prevAllMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        return self.filterAndPush(try getSiblingNodes(alloc, self.nodes, .prev_all, null, null), m);
    }

    /// Get all preceding siblings until a matcher/nodes boundary.
    pub fn prevUntil(self: Selection, opts: UntilOpts) !Selection {
        const alloc = self.document.allocator();
        const raw = try getSiblingNodes(alloc, self.nodes, .prev_until, opts.until, opts.until_nodes);
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
    pub fn filterMatcher(self: Selection, m: Matcher) !Selection {
        return self.pushStack(try winnow(self, m, true));
    }

    /// Filter using a reusable compiled selector.
    pub fn filterCompiled(self: Selection, compiled: *const CompiledSelector) !Selection {
        return self.filterMatcher(compiled.matcher(self.document.allocator()));
    }

    /// Filter using a callback function.
    pub fn filterFn(self: Selection, f: *const fn (usize, Selection) bool) !Selection {
        return self.pushStack(try winnowFn(self, f, true));
    }

    /// Filter to elements in the given node slice.
    pub fn filterNodes(self: Selection, target_nodes: []*Node) !Selection {
        return self.pushStack(try winnowNodes(self, target_nodes, true));
    }

    /// Filter to elements in the given Selection.
    pub fn filterSelection(self: Selection, sel: Selection) !Selection {
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
    pub fn notMatcher(self: Selection, m: Matcher) !Selection {
        return self.pushStack(try winnow(self, m, false));
    }

    /// Remove elements using a callback function.
    pub fn notFn(self: Selection, f: *const fn (usize, Selection) bool) !Selection {
        return self.pushStack(try winnowFn(self, f, false));
    }

    /// Remove elements matching specific nodes.
    pub fn notNodes(self: Selection, target_nodes: []*Node) !Selection {
        return self.pushStack(try winnowNodes(self, target_nodes, false));
    }

    /// Remove elements matching a Selection.
    pub fn notSelection(self: Selection, sel: Selection) !Selection {
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
    pub fn hasMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        for (self.nodes) |n| {
            if (hasDescendantMatch(n, m)) {
                try result.append(alloc, n);
            }
        }
        return self.pushStack(try result.toOwnedSlice(alloc));
    }

    /// Reduce to elements having a descendant matched by a compiled selector.
    pub fn hasCompiled(self: Selection, compiled: *const CompiledSelector) !Selection {
        return self.hasMatcher(compiled.matcher(self.document.allocator()));
    }

    /// Reduce to elements that have a descendant matching given nodes.
    pub fn hasNodes(self: Selection, target_nodes: []*Node) !Selection {
        const alloc = self.document.allocator();
        var result: std.ArrayList(*Node) = .empty;
        for (self.nodes) |n| {
            for (target_nodes) |target| {
                if (nodeContains(n, target)) {
                    try result.append(alloc, n);
                    break;
                }
            }
        }
        return self.pushStack(try result.toOwnedSlice(alloc));
    }

    /// Reduce to elements that have a descendant in the given Selection.
    pub fn hasSelection(self: Selection, sel: Selection) !Selection {
        return self.hasNodes(sel.nodes);
    }

    /// Alias for filterSelection.
    pub fn intersection(self: Selection, sel: Selection) !Selection {
        return self.filterSelection(sel);
    }

    /// Return to the previous selection in the chain.
    pub fn end(self: Selection) Selection {
        if (self.prev_sel) |p| return p.*;
        return Selection.initEmpty(self.document);
    }

    // Query.

    /// Check if any element matches the CSS selector.
    pub fn is(self: Selection, selector: []const u8) !bool {
        const alloc = self.document.allocator();
        const parsed = try css_parser.parseSelector(alloc, selector);
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

    /// Check if any element matches a reusable compiled selector.
    pub fn isCompiled(self: Selection, compiled: *const CompiledSelector) bool {
        return self.isMatcher(compiled.matcher(self.document.allocator()));
    }

    /// Check if any element matches using a callback.
    pub fn isFn(self: Selection, f: *const fn (usize, Selection) bool) bool {
        for (self.nodes, 0..) |_, i| {
            if (f(i, Selection.initFromSlice(self.nodes[i .. i + 1], self.document))) return true;
        }
        return false;
    }

    /// Check if any element matches a Selection.
    pub fn isSelection(self: Selection, sel: Selection) bool {
        return self.isNodes(sel.nodes);
    }

    /// Check if any element matches specific nodes.
    pub fn isNodes(self: Selection, target_nodes: []*Node) bool {
        for (self.nodes) |n| {
            if (isInSlice(target_nodes, n)) return true;
        }
        return false;
    }

    /// Check if `target` is a descendant of any node in this selection.
    /// Not inclusive (if target is in the selection itself, returns false).
    pub fn containsNode(self: Selection, target: *const Node) bool {
        return sliceContains(self.nodes, target);
    }

    // Array/Positional.

    /// First element.
    pub fn first(self: Selection) !Selection {
        return self.eq(0);
    }

    /// Last element.
    pub fn last(self: Selection) !Selection {
        return self.eq(-1);
    }

    /// Element at the given position. Negative indices count from the end.
    pub fn eq(self: Selection, pos: i64) !Selection {
        var idx = pos;
        if (idx < 0) idx += @as(i64, @intCast(self.nodes.len));
        if (idx < 0 or idx >= @as(i64, @intCast(self.nodes.len))) {
            return self.pushStack(&.{});
        }
        return self.eqPositive(@intCast(idx));
    }

    fn eqPositive(self: Selection, pos: usize) !Selection {
        return self.sliceRange(pos, pos + 1);
    }

    /// Slice of elements [start..end_idx).
    pub fn sliceRange(self: Selection, start: usize, end_idx: usize) !Selection {
        const s = @min(start, self.nodes.len);
        const e = @min(end_idx, self.nodes.len);
        if (s >= e) return self.pushStack(&.{});
        return self.pushStack(self.nodes[s..e]);
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
        var count: usize = 0;
        var sibling = self.nodes[0].prev_sibling;
        while (sibling) |node| : (sibling = node.prev_sibling) {
            if (node.node_type == .element) count += 1;
        }
        return count;
    }

    /// Position of first element relative to elements matching selector.
    pub fn indexOfSelector(self: Selection, selector: []const u8) !?usize {
        if (self.nodes.len == 0) return null;
        const doc_sel = try self.document.find(selector);
        return indexInSlice(doc_sel.nodes, self.nodes[0]);
    }

    /// Position of first element relative to elements matched by Matcher.
    pub fn indexOfMatcher(self: Selection, m: Matcher) !?usize {
        if (self.nodes.len == 0) return null;
        const doc_sel = try self.document.findMatcher(m);
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
        for (self.nodes, 0..) |_, i| {
            f(i, Selection.initFromSlice(self.nodes[i .. i + 1], self.document));
        }
    }

    /// Like each but the callback can return false to break.
    pub fn eachWithBreak(self: Selection, f: *const fn (usize, Selection) bool) void {
        for (self.nodes, 0..) |_, i| {
            if (!f(i, Selection.initFromSlice(self.nodes[i .. i + 1], self.document))) return;
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
            const pos = self.pos;
            self.pos += 1;
            return Selection.initFromSlice(self.sel.nodes[pos .. pos + 1], self.sel.document);
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
    pub fn setAttr(self: Selection, name: []const u8, val: []const u8) !void {
        const alloc = self.document.allocator();
        var pending: std.ArrayList(PendingAttribute) = .empty;
        for (self.nodes) |n| {
            if (n.node_type == .element) {
                try pending.append(alloc, try prepareSetAttribute(alloc, n, name, val));
            }
        }
        applyAttributeMutations(pending.items);
    }

    /// Remove a named attribute from all elements.
    pub fn removeAttr(self: Selection, name: []const u8) void {
        for (self.nodes) |n| {
            removeNodeAttr(n, name);
        }
    }

    /// Add CSS class(es) to all elements. Multiple classes separated by space.
    pub fn addClass(self: Selection, classes: []const u8) !void {
        try self.updateClasses(classes, .add);
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
    pub fn removeClass(self: Selection, classes: []const u8) !void {
        try self.updateClasses(classes, .remove);
    }

    /// Toggle CSS class(es) on all elements.
    pub fn toggleClass(self: Selection, classes: []const u8) !void {
        try self.updateClasses(classes, .toggle);
    }

    fn updateClasses(self: Selection, classes: []const u8, mode: ClassUpdateMode) !void {
        const alloc = self.document.allocator();
        var pending: std.ArrayList(PendingAttribute) = .empty;
        for (self.nodes) |n| {
            if (n.node_type != .element) continue;
            const update = try buildClassUpdate(alloc, n.getAttr("class"), classes, mode);
            if (!update.changed) continue;
            if (update.value) |value| {
                try pending.append(alloc, try prepareSetAttribute(alloc, n, "class", value));
            } else if (findAttributeIndex(n, "class")) |attribute_index| {
                try pending.append(alloc, .{ .remove = .{ .node = n, .index = attribute_index } });
            }
        }
        applyAttributeMutations(pending.items);
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
            try collectText(alloc, n, &buf);
        }
        return buf.toOwnedSlice(alloc);
    }

    // Manipulation.

    /// Insert nodes after each element in the selection.
    pub fn afterNodes(self: Selection, ns: []*Node) !void {
        const alloc = self.document.allocator();
        const prepared = try cloneNodesForTargets(alloc, self.nodes.len, ns);
        for (self.nodes, prepared) |sn, clones| {
            if (sn.parent == null) continue;
            const next_sibling = sn.next_sibling;
            for (clones) |node| {
                tree.insertBefore(sn.parent.?, node, next_sibling);
            }
        }
    }

    /// Insert HTML after each element.
    pub fn afterHtml(self: Selection, html_str: []const u8) !void {
        const alloc = self.document.allocator();
        const prepared = try prepareFragments(alloc, self.nodes, html_str, .parent);
        for (self.nodes, prepared) |n, nodes| {
            const parent_node = n.parent orelse continue;
            const next_sib = n.next_sibling;
            for (nodes) |new_node| {
                tree.insertBefore(parent_node, new_node, next_sib);
            }
        }
    }

    /// Insert nodes before each element.
    pub fn beforeNodes(self: Selection, ns: []*Node) !void {
        const alloc = self.document.allocator();
        const prepared = try cloneNodesForTargets(alloc, self.nodes.len, ns);
        for (self.nodes, prepared) |sn, clones| {
            if (sn.parent == null) continue;
            for (clones) |node| {
                tree.insertBefore(sn.parent.?, node, sn);
            }
        }
    }

    /// Insert HTML before each element.
    pub fn beforeHtml(self: Selection, html_str: []const u8) !void {
        const alloc = self.document.allocator();
        const prepared = try prepareFragments(alloc, self.nodes, html_str, .parent);
        for (self.nodes, prepared) |n, nodes| {
            const parent_node = n.parent orelse continue;
            for (nodes) |new_node| {
                tree.insertBefore(parent_node, new_node, n);
            }
        }
    }

    /// Append nodes as children of each element.
    pub fn appendNodes(self: Selection, ns: []*Node) !void {
        const alloc = self.document.allocator();
        const prepared = try cloneNodesForTargets(alloc, self.nodes.len, ns);
        for (self.nodes, prepared) |sn, clones| {
            if (sn.node_type != .element and sn.node_type != .document) continue;
            for (clones) |node| {
                tree.appendChild(sn, node);
            }
        }
    }

    /// Append parsed HTML as children of each element.
    pub fn appendHtml(self: Selection, html_str: []const u8) !void {
        const alloc = self.document.allocator();
        const prepared = try prepareFragments(alloc, self.nodes, html_str, .element);
        for (self.nodes, prepared) |n, nodes| {
            if (n.node_type != .element and n.node_type != .document) continue;
            for (nodes) |new_node| {
                tree.appendChild(n, new_node);
            }
        }
    }

    /// Prepend nodes as first children of each element.
    pub fn prependNodes(self: Selection, ns: []*Node) !void {
        const alloc = self.document.allocator();
        const prepared = try cloneNodesForTargets(alloc, self.nodes.len, ns);
        for (self.nodes, prepared) |sn, clones| {
            if (sn.node_type != .element and sn.node_type != .document) continue;
            const first_child = sn.first_child;
            for (clones) |node| {
                tree.insertBefore(sn, node, first_child);
            }
        }
    }

    /// Prepend parsed HTML.
    pub fn prependHtml(self: Selection, html_str: []const u8) !void {
        const alloc = self.document.allocator();
        const prepared = try prepareFragments(alloc, self.nodes, html_str, .element);
        for (self.nodes, prepared) |n, nodes| {
            if (n.node_type != .element and n.node_type != .document) continue;
            const first_child = n.first_child;
            for (nodes) |new_node| {
                tree.insertBefore(n, new_node, first_child);
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
    pub fn removeMatcher(self: Selection, m: Matcher) !Selection {
        return (try self.filterMatcher(m)).remove();
    }

    /// Replace each element with the given nodes.
    pub fn replaceWithNodes(self: Selection, ns: []*Node) !Selection {
        try self.afterNodes(ns);
        return self.remove();
    }

    /// Replace with parsed HTML.
    pub fn replaceWithHtml(self: Selection, html_str: []const u8) !Selection {
        try self.afterHtml(html_str);
        return self.remove();
    }

    /// Deep-clone the matched elements.
    pub fn cloneSel(self: Selection) !Selection {
        const alloc = self.document.allocator();
        const cloned = try tree.cloneNodes(alloc, self.nodes);
        return Selection.initFromSlice(cloned, self.document);
    }

    /// Remove all children from each element, returning removed children.
    pub fn empty(self: Selection) !Selection {
        const alloc = self.document.allocator();
        var removed: std.ArrayList(*Node) = .empty;
        for (self.nodes) |n| {
            var child = n.first_child;
            while (child) |current| : (child = current.next_sibling) {
                try removed.append(alloc, current);
            }
        }
        const removed_nodes = try removed.toOwnedSlice(alloc);
        const result = try self.pushStack(removed_nodes);
        for (self.nodes) |n| {
            while (n.first_child) |child| {
                tree.removeChild(n, child);
            }
        }
        return result;
    }

    /// Set inner HTML of each element.
    pub fn setHtml(self: Selection, html_str: []const u8) !void {
        const alloc = self.document.allocator();
        const prepared = try prepareFragments(alloc, self.nodes, html_str, .element);
        for (self.nodes) |n| {
            if (n.node_type != .element and n.node_type != .document) continue;
            while (n.first_child) |child| {
                tree.removeChild(n, child);
            }
        }
        for (self.nodes, prepared) |n, nodes| {
            if (n.node_type != .element and n.node_type != .document) continue;
            for (nodes) |node| tree.appendChild(n, node);
        }
    }

    /// Set literal text content.
    pub fn setText(self: Selection, text_str: []const u8) !void {
        const alloc = self.document.allocator();
        const prepared = try alloc.alloc(?*Node, self.nodes.len);
        for (self.nodes, prepared) |n, *text_node| {
            if (n.node_type != .element and n.node_type != .document) {
                text_node.* = null;
                continue;
            }
            const node = try alloc.create(Node);
            node.* = .{ .node_type = .text, .data = try alloc.dupe(u8, text_str) };
            text_node.* = node;
        }
        for (self.nodes, prepared) |n, text_node| {
            const node = text_node orelse continue;
            while (n.first_child) |child| tree.removeChild(n, child);
            tree.appendChild(n, node);
        }
    }

    /// Remove the parent of each element, leaving matched elements in place.
    pub fn unwrap(self: Selection) !void {
        const parent_sel = try self.parent();
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
    pub fn wrapNode(self: Selection, wrapper: *Node) !void {
        if (wrapper.node_type != .element) return error.InvalidWrapper;
        const alloc = self.document.allocator();
        const wraps = try cloneNodesForTargets(alloc, self.nodes.len, &.{wrapper});
        for (self.nodes, wraps) |n, clones| {
            const wrap = clones[0];
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
    pub fn wrapHtml(self: Selection, html_str: []const u8) !void {
        const alloc = self.document.allocator();
        const prepared = try prepareFragments(alloc, self.nodes, html_str, .parent_or_synthetic);
        for (prepared) |parsed| {
            if (parsed.len > 0 and firstElement(parsed) == null) return error.InvalidWrapper;
        }
        for (self.nodes, prepared) |n, parsed| {
            if (parsed.len == 0) continue;
            const wrap = firstElement(parsed).?;
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
    pub fn wrapAllNode(self: Selection, wrapper: *Node) !void {
        if (self.nodes.len == 0) return;
        if (wrapper.node_type != .element) return error.InvalidWrapper;
        const alloc = self.document.allocator();
        const wrap = try tree.cloneNode(alloc, wrapper);
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
    pub fn wrapInnerNode(self: Selection, wrapper: *Node) !void {
        if (wrapper.node_type != .element) return error.InvalidWrapper;
        const alloc = self.document.allocator();
        const wraps = try cloneNodesForTargets(alloc, self.nodes.len, &.{wrapper});
        for (self.nodes, wraps) |n, clones| {
            if (n.node_type != .element and n.node_type != .document) continue;
            const wrap = clones[0];
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
    pub fn addMatcher(self: Selection, m: Matcher) !Selection {
        const alloc = self.document.allocator();
        const root_slice = [_]*Node{self.document.root_node};
        const found = try findWithMatcher(alloc, @constCast(root_slice[0..]), m);
        return self.addNodes(found);
    }

    /// Add a Selection's nodes to this selection.
    pub fn addSelection(self: Selection, sel: Selection) !Selection {
        return self.addNodes(sel.nodes);
    }

    /// Add specific nodes to this selection.
    pub fn addNodes(self: Selection, extra_nodes: []*Node) !Selection {
        const alloc = self.document.allocator();
        const merged = try appendWithoutDuplicates(alloc, self.nodes, extra_nodes);
        return self.pushStack(merged);
    }

    /// Alias for addSelection.
    pub fn @"union"(self: Selection, sel: Selection) !Selection {
        return self.addSelection(sel);
    }

    /// Add back the previous selection.
    pub fn addBack(self: Selection) !Selection {
        if (self.prev_sel) |p| return self.addSelection(p.*);
        return self;
    }

    /// Add back the previous selection filtered by CSS selector.
    pub fn addBackFiltered(self: Selection, selector: []const u8) !Selection {
        if (self.prev_sel) |p| return self.addSelection(try p.filter(selector));
        return self;
    }

    // Internal helpers.

    fn pushStack(self: Selection, new_nodes: []*Node) !Selection {
        const alloc = self.document.allocator();
        const saved = try alloc.create(Selection);
        saved.* = self;
        return Selection{
            .nodes = new_nodes,
            .document = self.document,
            .prev_sel = saved,
        };
    }

    fn filterAndPush(self: Selection, raw_nodes: []*Node, m: Matcher) !Selection {
        const filtered = try filterWithMatcher(self.document.allocator(), raw_nodes, m);
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

fn cloneNodesForTargets(alloc: Allocator, target_count: usize, source: []const *Node) ![][]*Node {
    const prepared = try alloc.alloc([]*Node, target_count);
    for (prepared) |*clones| {
        clones.* = try alloc.alloc(*Node, source.len);
        for (source, clones.*) |node, *clone| {
            clone.* = try tree.cloneNode(alloc, node);
        }
    }
    return prepared;
}

const FragmentContext = enum {
    parent,
    element,
    parent_or_synthetic,
};

fn prepareFragments(alloc: Allocator, targets: []*Node, html: []const u8, mode: FragmentContext) ![][]*Node {
    const prepared = try alloc.alloc([]*Node, targets.len);
    for (targets, prepared) |target, *fragment| {
        const context = switch (mode) {
            .parent => target.parent orelse {
                fragment.* = &.{};
                continue;
            },
            .element => if (target.node_type == .element or target.node_type == .document)
                target
            else {
                fragment.* = &.{};
                continue;
            },
            .parent_or_synthetic => target.parent orelse blk: {
                const synthetic = try alloc.create(Node);
                synthetic.* = .{ .node_type = .element, .data = "div" };
                break :blk synthetic;
            },
        };
        fragment.* = try html_parser.parseFragment(alloc, html, context);
    }
    return prepared;
}

fn firstElement(nodes: []*Node) ?*Node {
    for (nodes) |node| {
        if (node.node_type == .element) return node;
    }
    return null;
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

fn getChildrenNodes(alloc: Allocator, nodes: []*Node, st: SiblingType) ![]*Node {
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
                try seen.put(c, {});
                try result.append(alloc, c);
            }
            child = c.next_sibling;
        }
    }
    return result.toOwnedSlice(alloc);
}

fn getParentNodes(alloc: Allocator, nodes: []*Node) ![]*Node {
    var result: std.ArrayList(*Node) = .empty;
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (nodes) |n| {
        if (n.parent) |p| {
            if (p.node_type == .element and !seen.contains(p)) {
                try seen.put(p, {});
                try result.append(alloc, p);
            }
        }
    }
    return result.toOwnedSlice(alloc);
}

fn getParentsNodes(alloc: Allocator, nodes: []*Node, until_matcher: ?Matcher, until_nodes: ?[]*Node) ![]*Node {
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
                try seen.put(parent, {});
                try result.append(alloc, parent);
            }
            p = parent.parent;
        }
    }
    return result.toOwnedSlice(alloc);
}

fn getSiblingNodes(alloc: Allocator, nodes: []*Node, st: SiblingType, until_matcher: ?Matcher, until_nodes: ?[]*Node) ![]*Node {
    var result: std.ArrayList(*Node) = .empty;
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (nodes) |n| {
        const siblings = try getNodeSiblings(alloc, n, st, until_matcher, until_nodes);
        for (siblings) |s| {
            if (!seen.contains(s)) {
                try seen.put(s, {});
                try result.append(alloc, s);
            }
        }
    }
    return result.toOwnedSlice(alloc);
}

fn getNodeSiblings(alloc: Allocator, node: *Node, st: SiblingType, until_matcher: ?Matcher, until_nodes: ?[]*Node) ![]*Node {
    var result: std.ArrayList(*Node) = .empty;
    const parent = node.parent orelse return result.toOwnedSlice(alloc);

    switch (st) {
        .all, .all_including_non_elements => {
            var c = parent.first_child;
            while (c) |child| {
                if (child != node and child.node_type == .element) {
                    try result.append(alloc, child);
                }
                c = child.next_sibling;
            }
        },
        .next => {
            var c = node.next_sibling;
            while (c) |child| {
                if (child.node_type == .element) {
                    try result.append(alloc, child);
                    break;
                }
                c = child.next_sibling;
            }
        },
        .next_all => {
            var c = node.next_sibling;
            while (c) |child| {
                if (child.node_type == .element) try result.append(alloc, child);
                c = child.next_sibling;
            }
        },
        .next_until => {
            var c = node.next_sibling;
            while (c) |child| {
                if (child.node_type == .element) {
                    if (matchesUntil(child, until_matcher, until_nodes)) break;
                    try result.append(alloc, child);
                }
                c = child.next_sibling;
            }
        },
        .prev => {
            var c = node.prev_sibling;
            while (c) |child| {
                if (child.node_type == .element) {
                    try result.append(alloc, child);
                    break;
                }
                c = child.prev_sibling;
            }
        },
        .prev_all => {
            var c = node.prev_sibling;
            while (c) |child| {
                if (child.node_type == .element) try result.append(alloc, child);
                c = child.prev_sibling;
            }
        },
        .prev_until => {
            var c = node.prev_sibling;
            while (c) |child| {
                if (child.node_type == .element) {
                    if (matchesUntil(child, until_matcher, until_nodes)) break;
                    try result.append(alloc, child);
                }
                c = child.prev_sibling;
            }
        },
    }
    return result.toOwnedSlice(alloc);
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

fn winnow(sel: Selection, m: Matcher, keep: bool) ![]*Node {
    if (keep) {
        return filterWithMatcher(sel.document.allocator(), sel.nodes, m);
    }
    const alloc = sel.document.allocator();
    var result: std.ArrayList(*Node) = .empty;
    for (sel.nodes) |n| {
        if (!m.match(n)) try result.append(alloc, n);
    }
    return result.toOwnedSlice(alloc);
}

fn filterWithMatcher(alloc: Allocator, nodes: []*Node, m: Matcher) ![]*Node {
    var result: std.ArrayList(*Node) = .empty;
    for (nodes) |node| {
        if (m.match(node)) try result.append(alloc, node);
    }
    return result.toOwnedSlice(alloc);
}

fn winnowFn(sel: Selection, f: *const fn (usize, Selection) bool, keep: bool) ![]*Node {
    const alloc = sel.document.allocator();
    var result: std.ArrayList(*Node) = .empty;
    for (sel.nodes, 0..) |n, i| {
        const matches = f(i, Selection.initFromSlice(sel.nodes[i .. i + 1], sel.document));
        if (matches == keep) try result.append(alloc, n);
    }
    return result.toOwnedSlice(alloc);
}

fn winnowNodes(sel: Selection, target_nodes: []*Node, keep: bool) ![]*Node {
    const alloc = sel.document.allocator();
    var result: std.ArrayList(*Node) = .empty;
    for (sel.nodes) |n| {
        const in_targets = isInSlice(target_nodes, n);
        if (in_targets == keep) try result.append(alloc, n);
    }
    return result.toOwnedSlice(alloc);
}

fn appendWithoutDuplicates(alloc: Allocator, target: []*Node, new_nodes: []*Node) ![]*Node {
    var result: std.ArrayList(*Node) = .empty;
    try result.appendSlice(alloc, target);
    var seen = std.AutoHashMap(*Node, void).init(alloc);
    for (target) |n| try seen.put(n, {});
    for (new_nodes) |n| {
        if (!seen.contains(n)) {
            try seen.put(n, {});
            try result.append(alloc, n);
        }
    }
    return result.toOwnedSlice(alloc);
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

fn collectText(alloc: Allocator, node: *const Node, buf: *std.ArrayList(u8)) !void {
    if (node.node_type == .text) {
        try buf.appendSlice(alloc, node.data);
        return;
    }
    var child = node.first_child;
    while (child) |c| {
        try collectText(alloc, c, buf);
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

const ClassUpdateMode = enum { add, remove, toggle };

const ClassUpdate = struct {
    changed: bool,
    value: ?[]const u8,
};

fn buildClassUpdate(alloc: Allocator, current: ?[]const u8, classes: []const u8, mode: ClassUpdateMode) !ClassUpdate {
    var tokens: std.ArrayList([]const u8) = .empty;
    var current_it = std.mem.tokenizeAny(u8, current orelse "", " \t\n\r");
    while (current_it.next()) |token| try tokens.append(alloc, token);

    var changed = false;
    var updates = std.mem.tokenizeAny(u8, classes, " \t\n\r");
    var had_updates = false;
    while (updates.next()) |class| {
        had_updates = true;
        switch (mode) {
            .add => if (indexOfString(tokens.items, class) == null) {
                try tokens.append(alloc, class);
                changed = true;
            },
            .remove => {
                if (removeAllStrings(&tokens, class)) changed = true;
            },
            .toggle => if (indexOfString(tokens.items, class) != null) {
                _ = removeAllStrings(&tokens, class);
                changed = true;
            } else {
                try tokens.append(alloc, class);
                changed = true;
            },
        }
    }

    if (mode == .remove and !had_updates) {
        return .{ .changed = current != null, .value = null };
    }
    if (!changed) return .{ .changed = false, .value = current };
    if (tokens.items.len == 0) return .{ .changed = true, .value = null };

    var rendered: std.ArrayList(u8) = .empty;
    for (tokens.items, 0..) |token, i| {
        if (i > 0) try rendered.append(alloc, ' ');
        try rendered.appendSlice(alloc, token);
    }
    return .{ .changed = true, .value = try rendered.toOwnedSlice(alloc) };
}

fn removeAllStrings(strings: *std.ArrayList([]const u8), target: []const u8) bool {
    var removed = false;
    while (indexOfString(strings.items, target)) |index| {
        _ = strings.orderedRemove(index);
        removed = true;
    }
    return removed;
}

fn indexOfString(strings: []const []const u8, target: []const u8) ?usize {
    for (strings, 0..) |string, i| {
        if (std.mem.eql(u8, string, target)) return i;
    }
    return null;
}

const PendingAttribute = union(enum) {
    set_existing: struct {
        node: *Node,
        index: usize,
        value: []const u8,
    },
    set_new: struct {
        node: *Node,
        attributes: []Attribute,
    },
    remove: struct {
        node: *Node,
        index: usize,
    },
};

fn prepareSetAttribute(alloc: Allocator, node: *Node, key: []const u8, val: []const u8) !PendingAttribute {
    const owned_val = try alloc.dupe(u8, val);
    if (findAttributeIndex(node, key)) |index| {
        return .{ .set_existing = .{ .node = node, .index = index, .value = owned_val } };
    }

    const owned_key = try alloc.dupe(u8, key);
    const new_attrs = try alloc.alloc(Attribute, node.attr.len + 1);
    @memcpy(new_attrs[0..node.attr.len], node.attr);
    new_attrs[node.attr.len] = .{ .key = owned_key, .val = owned_val };
    return .{ .set_new = .{ .node = node, .attributes = new_attrs } };
}

fn applyAttributeMutations(mutations: []const PendingAttribute) void {
    for (mutations) |mutation| switch (mutation) {
        .set_existing => |set| set.node.attr[set.index].val = set.value,
        .set_new => |set| set.node.attr = set.attributes,
        .remove => |remove| removeNodeAttrAt(remove.node, remove.index),
    };
}

fn findAttributeIndex(node: *const Node, key: []const u8) ?usize {
    for (node.attr, 0..) |attribute, i| {
        if (std.ascii.eqlIgnoreCase(attribute.key, key)) return i;
    }
    return null;
}

fn removeNodeAttr(node: *Node, key: []const u8) void {
    const index = findAttributeIndex(node, key) orelse return;
    removeNodeAttrAt(node, index);
}

fn removeNodeAttrAt(node: *Node, index: usize) void {
    const last = node.attr.len - 1;
    if (index != last) node.attr[index] = node.attr[last];
    node.attr = node.attr[0..last];
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
    const spans = try div.children();
    try std.testing.expect(spans.len() == 2);
}

test "Selection parent" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div><p>test</p></div>");
    defer doc.deinit();
    const p = try doc.find("p");
    const par = try p.parent();
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
    try std.testing.expect((try lis.first()).len() == 1);
    try std.testing.expect((try lis.last()).len() == 1);
}

test "Selection is" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div class=\"active\">test</div>");
    defer doc.deinit();
    const div = try doc.find("div");
    try std.testing.expect(try div.is(".active"));
    try std.testing.expect(!try div.is(".inactive"));
}

test "Selection empty selection" {
    var doc = try Document.initFromSlice(std.testing.allocator, "<div></div>");
    defer doc.deinit();
    const nonexistent = try doc.find("span");
    try std.testing.expect(nonexistent.len() == 0);
    try std.testing.expect(nonexistent.attr("id") == null);
    try std.testing.expect(!nonexistent.hasClass("foo"));
}
