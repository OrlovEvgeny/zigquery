const std = @import("std");
const Allocator = std.mem.Allocator;
const sel_mod = @import("selector.zig");
const Selector = sel_mod.Selector;
const AttrSelector = sel_mod.AttrSelector;
const AttrOp = sel_mod.AttrOp;
const Combinator = sel_mod.Combinator;
const CombinatorKind = sel_mod.CombinatorKind;
const PseudoClassSelector = sel_mod.PseudoClassSelector;
const PseudoClassKind = sel_mod.PseudoClassKind;

pub const CssParseError = error{
    InvalidSelector,
    UnexpectedToken,
    UnexpectedEof,
    InvalidNthExpression,
    OutOfMemory,
};

/// Parse a CSS selector string into a Selector AST.
/// All allocations go through the provided allocator (typically an arena).
pub fn parseSelector(allocator: Allocator, input: []const u8) CssParseError!*const Selector {
    var p = CssParser.init(allocator, input);
    return p.parseSelectorList();
}

const CssParser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,

    fn init(allocator: Allocator, input: []const u8) CssParser {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
        };
    }

    // Selector list: sel1, sel2, ...
    fn parseSelectorList(self: *CssParser) CssParseError!*const Selector {
        _ = self.skipWhitespace();
        const first = try self.parseComplexSelector();

        _ = self.skipWhitespace();
        if (self.pos >= self.input.len or self.peek() != ',') {
            return first;
        }

        var selectors: std.ArrayList(*const Selector) = .empty;
        try selectors.append(self.allocator, first);

        while (self.pos < self.input.len and self.peek() == ',') {
            self.advance(); // skip ','
            _ = self.skipWhitespace();
            const next = try self.parseComplexSelector();
            try selectors.append(self.allocator, next);
            _ = self.skipWhitespace();
        }

        const group = try self.create(Selector{ .group = try selectors.toOwnedSlice(self.allocator) });
        return group;
    }

    // Complex selector: compound (combinator compound)*
    fn parseComplexSelector(self: *CssParser) CssParseError!*const Selector {
        var left = try self.parseCompoundSelector();

        while (self.pos < self.input.len) {
            const had_ws = self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            const c = self.peek();
            if (c == ',' or c == ')') break;

            var kind: CombinatorKind = undefined;
            if (c == '>') {
                kind = .child;
                self.advance();
                _ = self.skipWhitespace();
            } else if (c == '+') {
                kind = .next_sibling;
                self.advance();
                _ = self.skipWhitespace();
            } else if (c == '~') {
                kind = .subsequent_sibling;
                self.advance();
                _ = self.skipWhitespace();
            } else if (had_ws) {
                kind = .descendant;
            } else {
                break;
            }

            const right = try self.parseCompoundSelector();
            const comb = try self.create(Selector{ .combinator = .{
                .kind = kind,
                .left = left,
                .right = right,
            } });
            left = comb;
        }

        return left;
    }

    // Compound selector: simple_selector+
    fn parseCompoundSelector(self: *CssParser) CssParseError!*const Selector {
        var parts: std.ArrayList(*const Selector) = .empty;

        while (self.pos < self.input.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
                c == '>' or c == '+' or c == '~' or c == ',' or c == ')')
            {
                break;
            }
            const simple = try self.parseSimpleSelector();
            try parts.append(self.allocator, simple);
        }

        if (parts.items.len == 0) return CssParseError.UnexpectedToken;
        if (parts.items.len == 1) return parts.items[0];

        return self.create(Selector{ .compound = try parts.toOwnedSlice(self.allocator) });
    }

    fn parseSimpleSelector(self: *CssParser) CssParseError!*const Selector {
        if (self.pos >= self.input.len) return CssParseError.UnexpectedEof;

        const c = self.peek();

        if (c == '#') return self.parseIdSelector();
        if (c == '.') return self.parseClassSelector();
        if (c == '[') return self.parseAttrSelector();
        if (c == ':') return self.parsePseudoSelector();
        if (c == '*') {
            self.advance();
            return self.create(Selector{ .universal = {} });
        }

        return self.parseTagSelector();
    }

    fn parseTagSelector(self: *CssParser) CssParseError!*const Selector {
        const name = try self.parseIdentifier();
        return self.create(Selector{ .tag = name });
    }

    fn parseIdSelector(self: *CssParser) CssParseError!*const Selector {
        self.advance(); // skip '#'
        const name = try self.parseIdentifier();
        return self.create(Selector{ .id = name });
    }

    fn parseClassSelector(self: *CssParser) CssParseError!*const Selector {
        self.advance(); // skip '.'
        const name = try self.parseIdentifier();
        return self.create(Selector{ .class = name });
    }

    fn parseAttrSelector(self: *CssParser) CssParseError!*const Selector {
        self.advance(); // skip '['
        _ = self.skipWhitespace();

        const key = try self.parseIdentifier();
        _ = self.skipWhitespace();

        if (self.pos >= self.input.len) return CssParseError.UnexpectedEof;

        if (self.peek() == ']') {
            self.advance();
            return self.create(Selector{ .attr = .{ .key = key } });
        }

        // Parse operator.
        const op = try self.parseAttrOp();
        _ = self.skipWhitespace();

        const val = try self.parseStringOrIdent();
        _ = self.skipWhitespace();

        var case_insensitive = false;
        if (self.pos < self.input.len and (self.peek() == 'i' or self.peek() == 'I')) {
            case_insensitive = true;
            self.advance();
            _ = self.skipWhitespace();
        }

        if (self.pos >= self.input.len or self.peek() != ']') return CssParseError.UnexpectedToken;
        self.advance(); // skip ']'

        return self.create(Selector{ .attr = .{
            .key = key,
            .op = op,
            .val = val,
            .case_insensitive = case_insensitive,
        } });
    }

    fn parseAttrOp(self: *CssParser) CssParseError!AttrOp {
        if (self.pos >= self.input.len) return CssParseError.UnexpectedEof;

        const c = self.peek();
        if (c == '=') {
            self.advance();
            return .equals;
        }
        if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
            const op: AttrOp = switch (c) {
                '~' => .includes,
                '|' => .dash_match,
                '^' => .prefix,
                '$' => .suffix,
                '*' => .substring,
                else => return CssParseError.UnexpectedToken,
            };
            self.pos += 2;
            return op;
        }

        return CssParseError.UnexpectedToken;
    }

    fn parsePseudoSelector(self: *CssParser) CssParseError!*const Selector {
        self.advance(); // skip first ':'
        // Skip optional second ':' for pseudo-elements (we treat them as pseudo-classes).
        if (self.pos < self.input.len and self.peek() == ':') self.advance();

        const name = try self.parseIdentifier();

        // Functional pseudo-classes.
        if (self.pos < self.input.len and self.peek() == '(') {
            self.advance(); // skip '('
            _ = self.skipWhitespace();

            if (std.mem.eql(u8, name, "not")) {
                const inner = try self.parseComplexSelector();
                _ = self.skipWhitespace();
                if (self.pos >= self.input.len or self.peek() != ')') return CssParseError.UnexpectedToken;
                self.advance();
                return self.create(Selector{ .not = inner });
            }
            if (std.mem.eql(u8, name, "has")) {
                const inner = try self.parseComplexSelector();
                _ = self.skipWhitespace();
                if (self.pos >= self.input.len or self.peek() != ')') return CssParseError.UnexpectedToken;
                self.advance();
                return self.create(Selector{ .has_pseudo = inner });
            }
            if (std.mem.eql(u8, name, "contains")) {
                const text = try self.parseStringOrIdent();
                _ = self.skipWhitespace();
                if (self.pos >= self.input.len or self.peek() != ')') return CssParseError.UnexpectedToken;
                self.advance();
                return self.create(Selector{ .contains = text });
            }

            // :nth-* functions.
            const nth_kind = nthKindFromName(name) orelse return CssParseError.InvalidSelector;
            const ab = try self.parseNthExpression();
            _ = self.skipWhitespace();
            if (self.pos >= self.input.len or self.peek() != ')') return CssParseError.UnexpectedToken;
            self.advance();
            return self.create(Selector{ .pseudo_class = .{
                .kind = nth_kind,
                .a = ab[0],
                .b = ab[1],
            } });
        }

        // Non-functional pseudo-classes.
        const kind = pseudoKindFromName(name) orelse return CssParseError.InvalidSelector;
        return self.create(Selector{ .pseudo_class = .{ .kind = kind } });
    }

    fn parseNthExpression(self: *CssParser) CssParseError![2]i32 {
        _ = self.skipWhitespace();
        if (self.pos >= self.input.len) return CssParseError.UnexpectedEof;

        // "odd"
        if (self.matchKeyword("odd")) return .{ 2, 1 };
        // "even"
        if (self.matchKeyword("even")) return .{ 2, 0 };

        var a: i32 = 0;
        var b: i32 = 0;
        var sign: i32 = 1;

        if (self.peek() == '-') {
            sign = -1;
            self.advance();
        } else if (self.peek() == '+') {
            self.advance();
        }

        if (self.pos < self.input.len and self.peek() == 'n') {
            // "n", "-n", "+n"
            a = sign;
            self.advance();
        } else if (self.pos < self.input.len and std.ascii.isDigit(self.peek())) {
            const num = self.parseNumber();
            if (self.pos < self.input.len and self.peek() == 'n') {
                a = sign * num;
                self.advance();
            } else {
                // Just a number: b.
                return .{ 0, sign * num };
            }
        } else {
            return CssParseError.InvalidNthExpression;
        }

        _ = self.skipWhitespace();
        if (self.pos < self.input.len) {
            if (self.peek() == '+') {
                self.advance();
                _ = self.skipWhitespace();
                b = self.parseNumber();
            } else if (self.peek() == '-') {
                self.advance();
                _ = self.skipWhitespace();
                b = -self.parseNumber();
            }
        }

        return .{ a, b };
    }

    fn parseNumber(self: *CssParser) i32 {
        var result: i32 = 0;
        while (self.pos < self.input.len and std.ascii.isDigit(self.peek())) {
            result = result * 10 + @as(i32, @intCast(self.peek() - '0'));
            self.advance();
        }
        return result;
    }

    fn matchKeyword(self: *CssParser, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.input.len) return false;
        if (std.ascii.eqlIgnoreCase(self.input[self.pos .. self.pos + keyword.len], keyword)) {
            // Verify no more identifier chars follow.
            if (self.pos + keyword.len < self.input.len and isIdentChar(self.input[self.pos + keyword.len])) {
                return false;
            }
            self.pos += keyword.len;
            return true;
        }
        return false;
    }

    fn parseIdentifier(self: *CssParser) CssParseError![]const u8 {
        const start = self.pos;
        // Allow leading hyphen or underscore.
        if (self.pos < self.input.len and (self.peek() == '-' or self.peek() == '_')) {
            self.advance();
        }
        while (self.pos < self.input.len and isIdentChar(self.peek())) {
            self.advance();
        }
        if (self.pos == start) return CssParseError.UnexpectedToken;
        return self.input[start..self.pos];
    }

    fn parseStringOrIdent(self: *CssParser) CssParseError![]const u8 {
        if (self.pos >= self.input.len) return CssParseError.UnexpectedEof;

        const c = self.peek();
        if (c == '"' or c == '\'') {
            return self.parseString(c);
        }
        return self.parseIdentifier();
    }

    fn parseString(self: *CssParser, quote: u8) CssParseError![]const u8 {
        self.advance(); // skip opening quote
        const start = self.pos;
        while (self.pos < self.input.len and self.peek() != quote) {
            if (self.peek() == '\\') {
                self.advance(); // skip escape
            }
            self.advance();
        }
        const result = self.input[start..self.pos];
        if (self.pos < self.input.len) self.advance(); // skip closing quote
        return result;
    }

    fn peek(self: *const CssParser) u8 {
        return self.input[self.pos];
    }

    fn advance(self: *CssParser) void {
        self.pos += 1;
    }

    fn skipWhitespace(self: *CssParser) bool {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
        return self.pos > start;
    }

    fn create(self: *CssParser, sel: Selector) CssParseError!*const Selector {
        const ptr = self.allocator.create(Selector) catch return CssParseError.OutOfMemory;
        ptr.* = sel;
        return ptr;
    }
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn pseudoKindFromName(name: []const u8) ?PseudoClassKind {
    const map = std.StaticStringMap(PseudoClassKind).initComptime(.{
        .{ "first-child", .first_child },
        .{ "last-child", .last_child },
        .{ "only-child", .only_child },
        .{ "first-of-type", .first_of_type },
        .{ "last-of-type", .last_of_type },
        .{ "only-of-type", .only_of_type },
        .{ "empty", .empty },
        .{ "root", .root },
        .{ "enabled", .enabled },
        .{ "disabled", .disabled },
        .{ "checked", .checked },
    });
    return map.get(name);
}

fn nthKindFromName(name: []const u8) ?PseudoClassKind {
    const map = std.StaticStringMap(PseudoClassKind).initComptime(.{
        .{ "nth-child", .nth_child },
        .{ "nth-last-child", .nth_last_child },
        .{ "nth-of-type", .nth_of_type },
        .{ "nth-last-of-type", .nth_last_of_type },
    });
    return map.get(name);
}

test "parse tag selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), "div");
    try std.testing.expect(sel.* == .tag);
    try std.testing.expectEqualStrings("div", sel.tag);
}

test "parse id selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), "#main");
    try std.testing.expect(sel.* == .id);
    try std.testing.expectEqualStrings("main", sel.id);
}

test "parse class selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), ".active");
    try std.testing.expect(sel.* == .class);
    try std.testing.expectEqualStrings("active", sel.class);
}

test "parse compound selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), "div.foo#bar");
    try std.testing.expect(sel.* == .compound);
    try std.testing.expect(sel.compound.len == 3);
}

test "parse descendant combinator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), "div p");
    try std.testing.expect(sel.* == .combinator);
    try std.testing.expect(sel.combinator.kind == .descendant);
}

test "parse child combinator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), "div > p");
    try std.testing.expect(sel.* == .combinator);
    try std.testing.expect(sel.combinator.kind == .child);
}

test "parse attribute selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), "[href=\"/test\"]");
    try std.testing.expect(sel.* == .attr);
    try std.testing.expectEqualStrings("href", sel.attr.key);
    try std.testing.expect(sel.attr.op == .equals);
    try std.testing.expectEqualStrings("/test", sel.attr.val);
}

test "parse group selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), "div, span, p");
    try std.testing.expect(sel.* == .group);
    try std.testing.expect(sel.group.len == 3);
}

test "parse pseudo-class selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), ":first-child");
    try std.testing.expect(sel.* == .pseudo_class);
    try std.testing.expect(sel.pseudo_class.kind == .first_child);
}

test "parse :nth-child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), ":nth-child(2n+1)");
    try std.testing.expect(sel.* == .pseudo_class);
    try std.testing.expect(sel.pseudo_class.kind == .nth_child);
    try std.testing.expect(sel.pseudo_class.a == 2);
    try std.testing.expect(sel.pseudo_class.b == 1);
}

test "parse :not selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), ":not(.hidden)");
    try std.testing.expect(sel.* == .not);
    try std.testing.expect(sel.not.* == .class);
}

test "parse universal selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sel = try parseSelector(arena.allocator(), "*");
    try std.testing.expect(sel.* == .universal);
}
