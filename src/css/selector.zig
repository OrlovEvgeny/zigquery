const std = @import("std");

pub const Selector = union(enum) {
    tag: []const u8,
    id: []const u8,
    class: []const u8,
    universal: void,
    attr: AttrSelector,
    pseudo_class: PseudoClassSelector,

    /// Combinator linking two selectors (descendant, child, sibling, adjacent).
    combinator: Combinator,

    /// Intersection — all sub-selectors must match (e.g. div.foo#bar).
    compound: []const *const Selector,

    /// Union — any sub-selector can match (e.g. sel1, sel2).
    group: []const *const Selector,

    /// Negation pseudo-class.
    not: *const Selector,

    /// :has() pseudo-class.
    has_pseudo: *const Selector,

    /// :contains("text") pseudo-class.
    contains: []const u8,
};

pub const AttrOp = enum {
    exists,
    equals,
    includes,
    dash_match,
    prefix,
    suffix,
    substring,
};

pub const AttrSelector = struct {
    key: []const u8,
    op: AttrOp = .exists,
    val: []const u8 = "",
    case_insensitive: bool = false,
};

pub const CombinatorKind = enum {
    descendant,
    child,
    next_sibling,
    subsequent_sibling,
};

pub const Combinator = struct {
    kind: CombinatorKind,
    left: *const Selector,
    right: *const Selector,
};

pub const PseudoClassKind = enum {
    first_child,
    last_child,
    only_child,
    first_of_type,
    last_of_type,
    only_of_type,
    empty,
    root,
    nth_child,
    nth_last_child,
    nth_of_type,
    nth_last_of_type,
    enabled,
    disabled,
    checked,
};

pub const PseudoClassSelector = struct {
    kind: PseudoClassKind,
    // For :nth-* selectors: an+b
    a: i32 = 0,
    b: i32 = 0,
};

test "selector union size" {
    // Verify the tagged union is reasonably sized.
    try std.testing.expect(@sizeOf(Selector) <= 64);
}
