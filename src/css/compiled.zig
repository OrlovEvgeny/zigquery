const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../dom/node.zig").Node;
const Selector = @import("selector.zig").Selector;
const parser = @import("parser.zig");
const matcher_mod = @import("matcher.zig");
const Matcher = matcher_mod.Matcher;

/// An owning, reusable CSS selector. Deinitialize it only after all matching
/// operations using it have completed.
pub const CompiledSelector = struct {
    arena: std.heap.ArenaAllocator,
    selector: *const Selector,

    pub fn init(backing: Allocator, source: []const u8) !CompiledSelector {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const owned_source = try arena.allocator().dupe(u8, source);
        const selector = try parser.parseSelector(arena.allocator(), owned_source);
        return .{ .arena = arena, .selector = selector };
    }

    pub fn deinit(self: *CompiledSelector) void {
        self.arena.deinit();
    }

    /// Test a node without allocating.
    pub fn match(self: *const CompiledSelector, node: *const Node) bool {
        return matcher_mod.matchNode(self.selector, node);
    }

    /// Create a lightweight Matcher whose result buffers use `allocator`.
    pub fn matcher(self: *const CompiledSelector, allocator: Allocator) Matcher {
        return Matcher.init(allocator, self.selector);
    }
};

test "compiled selector can be reused" {
    var compiled = try CompiledSelector.init(std.testing.allocator, "div.active");
    defer compiled.deinit();

    const attrs = [_]@import("../dom/node.zig").Attribute{.{ .key = "class", .val = "active" }};
    var node = Node{ .node_type = .element, .data = "div", .attr = @constCast(attrs[0..]) };
    try std.testing.expect(compiled.match(&node));
}
