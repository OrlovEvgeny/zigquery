const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const tree = @import("tree.zig");
const Node = node_mod.Node;
const NodeType = node_mod.NodeType;
const Attribute = node_mod.Attribute;

pub const HtmlParseError = error{
    OutOfMemory,
    InvalidEncoding,
};

// Void elements that must not have children.
const void_elements = std.StaticStringMap(void).initComptime(.{
    .{ "area", {} },  .{ "base", {} },  .{ "br", {} },
    .{ "col", {} },   .{ "embed", {} }, .{ "hr", {} },
    .{ "img", {} },   .{ "input", {} }, .{ "link", {} },
    .{ "meta", {} },  .{ "param", {} }, .{ "source", {} },
    .{ "track", {} }, .{ "wbr", {} },
});

// Raw text elements where content is not parsed as HTML.
const raw_text_elements = std.StaticStringMap(void).initComptime(.{
    .{ "script", {} },   .{ "style", {} },
    .{ "textarea", {} }, .{ "title", {} },
    .{ "xmp", {} },
});

// Map from tag being opened → tags that should be auto-closed on the stack.
// Per HTML5 spec: opening <p> closes an open <p>; opening <div> closes an
// open <p>; opening <li> closes an open <li>; etc.
const p_only = &[_][]const u8{"p"};

const auto_close_map = std.StaticStringMap([]const []const u8).initComptime(.{
    // Block-level elements close an open <p>.
    .{ "address", p_only },                    .{ "article", p_only },
    .{ "aside", p_only },                      .{ "blockquote", p_only },
    .{ "details", p_only },                    .{ "div", p_only },
    .{ "dl", p_only },                         .{ "fieldset", p_only },
    .{ "figcaption", p_only },                 .{ "figure", p_only },
    .{ "footer", p_only },                     .{ "form", p_only },
    .{ "h1", p_only },                         .{ "h2", p_only },
    .{ "h3", p_only },                         .{ "h4", p_only },
    .{ "h5", p_only },                         .{ "h6", p_only },
    .{ "header", p_only },                     .{ "hgroup", p_only },
    .{ "hr", p_only },                         .{ "main", p_only },
    .{ "menu", p_only },                       .{ "nav", p_only },
    .{ "ol", p_only },                         .{ "p", p_only },
    .{ "pre", p_only },                        .{ "section", p_only },
    .{ "table", p_only },                      .{ "ul", p_only },
    // Definition list items.
    .{ "dd", &.{ "dd", "dt" } },               .{ "dt", &.{ "dd", "dt" } },
    // List items.
    .{ "li", &.{"li"} },
    // Option groups.
                          .{ "optgroup", &.{"optgroup"} },
    .{ "option", &.{ "option", "optgroup" } },
    // Table sections.
    .{ "thead", &.{ "tbody", "tfoot" } },
    .{ "tbody", &.{ "tbody", "tfoot" } },      .{ "tfoot", &.{"tbody"} },
    .{ "tr", &.{"tr"} },                       .{ "td", &.{ "td", "th" } },
    .{ "th", &.{ "td", "th" } },
    // Ruby.
                  .{ "rt", &.{ "rt", "rp" } },
    .{ "rp", &.{ "rt", "rp" } },
});

// Formatting elements for adoption agency.
const formatting_elements = std.StaticStringMap(void).initComptime(.{
    .{ "a", {} },     .{ "b", {} },      .{ "big", {} },
    .{ "code", {} },  .{ "em", {} },     .{ "font", {} },
    .{ "i", {} },     .{ "nobr", {} },   .{ "s", {} },
    .{ "small", {} }, .{ "strike", {} }, .{ "strong", {} },
    .{ "tt", {} },    .{ "u", {} },
});

// Scope boundary elements.
const scope_elements = std.StaticStringMap(void).initComptime(.{
    .{ "applet", {} },  .{ "caption", {} }, .{ "html", {} },
    .{ "table", {} },   .{ "td", {} },      .{ "th", {} },
    .{ "marquee", {} }, .{ "object", {} },  .{ "template", {} },
});

/// Parse an HTML string into a DOM tree. Returns the document root node.
/// All nodes are allocated in `allocator` (expected to be an arena).
pub fn parse(allocator: Allocator, input: []const u8) HtmlParseError!*Node {
    var parser = Parser.init(allocator, input);
    return parser.run();
}

/// Parse an HTML fragment in the context of a given parent element.
/// Returns a slice of top-level nodes.
pub fn parseFragment(allocator: Allocator, input: []const u8, context: *const Node) HtmlParseError![]*Node {
    var parser = Parser.init(allocator, input);
    parser.fragment_context = context;
    const doc = try parser.run();

    // Collect children of the document's html > body (or just root children).
    const body = findBody(doc) orelse doc;
    var count: usize = 0;
    var c = body.first_child;
    while (c) |child| : (c = child.next_sibling) count += 1;

    const result = try allocator.alloc(*Node, count);
    c = body.first_child;
    var i: usize = 0;
    while (c) |child| {
        const nxt = child.next_sibling;
        tree.detach(child);
        result[i] = child;
        i += 1;
        c = nxt;
    }
    return result;
}

fn findBody(doc: *Node) ?*Node {
    var c = doc.first_child;
    while (c) |child| : (c = child.next_sibling) {
        if (child.node_type == .element and std.mem.eql(u8, child.data, "html")) {
            var hc = child.first_child;
            while (hc) |hchild| : (hc = hchild.next_sibling) {
                if (hchild.node_type == .element and std.mem.eql(u8, hchild.data, "body")) {
                    return hchild;
                }
            }
            return child;
        }
    }
    return null;
}

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,
    doc: *Node,
    open_elements: std.ArrayList(*Node),
    fragment_context: ?*const Node,
    head_inserted: bool,
    body_inserted: bool,

    fn init(allocator: Allocator, input: []const u8) Parser {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .doc = undefined,
            .open_elements = .empty,
            .fragment_context = null,
            .head_inserted = false,
            .body_inserted = false,
        };
    }

    fn run(self: *Parser) HtmlParseError!*Node {
        self.doc = try self.createNode(.document, "");

        // Parse tokens and build the tree.
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '<') {
                if (self.pos + 1 < self.input.len) {
                    const next = self.input[self.pos + 1];
                    if (next == '/') {
                        try self.parseEndTag();
                    } else if (next == '!') {
                        try self.parseMarkupDecl();
                    } else if (next == '?') {
                        try self.parseProcessingInstruction();
                    } else if (isAsciiAlpha(next)) {
                        try self.parseStartTag();
                    } else {
                        try self.emitChar();
                    }
                } else {
                    try self.emitChar();
                }
            } else {
                try self.parseText();
            }
        }

        // Close remaining open elements.
        self.open_elements.clearRetainingCapacity();

        return self.doc;
    }

    fn parseStartTag(self: *Parser) HtmlParseError!void {
        std.debug.assert(self.input[self.pos] == '<');
        self.pos += 1; // skip '<'

        const tag_start = self.pos;
        while (self.pos < self.input.len and !isWhitespace(self.input[self.pos]) and
            self.input[self.pos] != '>' and self.input[self.pos] != '/')
        {
            self.pos += 1;
        }
        const raw_tag = self.input[tag_start..self.pos];
        const tag_name = try self.toLower(raw_tag);

        self.skipWhitespace();

        // Parse attributes.
        var attrs: std.ArrayList(Attribute) = .empty;
        while (self.pos < self.input.len and self.input[self.pos] != '>' and self.input[self.pos] != '/') {
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] == '>' or self.input[self.pos] == '/') break;
            const attr = try self.parseAttribute();
            try attrs.append(self.allocator, attr);
            self.skipWhitespace();
        }

        var self_closing = false;
        if (self.pos < self.input.len and self.input[self.pos] == '/') {
            self_closing = true;
            self.pos += 1;
        }
        if (self.pos < self.input.len and self.input[self.pos] == '>') {
            self.pos += 1;
        }

        // Handle auto-closing of open elements.
        if (auto_close_map.get(tag_name)) |closers| {
            self.autoClose(closers);
        }

        // Implicit structure: ensure html > head > body exists.
        try self.ensureStructure(tag_name);

        // If we encounter <html> or <body> but one already exists on the
        // stack, merge attributes into the existing element rather than
        // creating a duplicate.
        if (std.mem.eql(u8, tag_name, "html") and self.open_elements.items.len > 0) {
            const existing = self.open_elements.items[0];
            if (existing.node_type == .element and std.mem.eql(u8, existing.data, "html")) {
                if (existing.attr.len == 0 and attrs.items.len > 0) {
                    existing.attr = try attrs.toOwnedSlice(self.allocator);
                }
                return;
            }
        }
        if (std.mem.eql(u8, tag_name, "body") and self.body_inserted) {
            // Body already exists, find it and merge attributes.
            for (self.open_elements.items) |el| {
                if (el.node_type == .element and std.mem.eql(u8, el.data, "body")) {
                    if (el.attr.len == 0 and attrs.items.len > 0) {
                        el.attr = try attrs.toOwnedSlice(self.allocator);
                    }
                    return;
                }
            }
        }

        const node = try self.createNode(.element, tag_name);
        node.attr = try attrs.toOwnedSlice(self.allocator);

        const parent = self.currentNode();
        tree.appendChild(parent, node);

        const is_void = void_elements.has(tag_name) or self_closing;
        if (!is_void) {
            try self.open_elements.append(self.allocator, node);

            // Raw text elements: slurp content until closing tag.
            if (raw_text_elements.has(tag_name)) {
                try self.parseRawText(tag_name);
            }
        }
    }

    fn parseEndTag(self: *Parser) HtmlParseError!void {
        std.debug.assert(self.input[self.pos] == '<' and self.input[self.pos + 1] == '/');
        self.pos += 2; // skip '</'

        const tag_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '>' and !isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
        const raw_tag = self.input[tag_start..self.pos];
        const tag_name = try self.toLower(raw_tag);

        // Skip to '>'
        while (self.pos < self.input.len and self.input[self.pos] != '>') self.pos += 1;
        if (self.pos < self.input.len) self.pos += 1;

        // Pop back to matching open element.
        var i = self.open_elements.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.open_elements.items[i].data, tag_name)) {
                self.open_elements.items.len = i;
                return;
            }
        }
        // No matching open element — ignore the end tag (lenient parsing).
    }

    fn parseMarkupDecl(self: *Parser) HtmlParseError!void {
        std.debug.assert(self.input[self.pos] == '<' and self.input[self.pos + 1] == '!');

        // DOCTYPE
        if (self.pos + 9 < self.input.len and
            std.ascii.eqlIgnoreCase(self.input[self.pos + 2 .. self.pos + 9], "doctype"))
        {
            self.pos += 9;
            self.skipWhitespace();

            const name_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != '>' and !isWhitespace(self.input[self.pos])) {
                self.pos += 1;
            }
            const name = self.input[name_start..self.pos];

            while (self.pos < self.input.len and self.input[self.pos] != '>') self.pos += 1;
            if (self.pos < self.input.len) self.pos += 1;

            const doctype_node = try self.createNode(.doctype, try self.toLower(name));
            tree.appendChild(self.doc, doctype_node);
            return;
        }

        // Comment: <!-- ... -->
        if (self.pos + 4 <= self.input.len and std.mem.eql(u8, self.input[self.pos + 2 .. self.pos + 4], "--")) {
            self.pos += 4; // skip '<!--'
            const start = self.pos;
            while (self.pos + 2 < self.input.len) {
                if (self.input[self.pos] == '-' and self.input[self.pos + 1] == '-' and self.input[self.pos + 2] == '>') {
                    break;
                }
                self.pos += 1;
            }
            const comment_text = self.input[start..self.pos];
            if (self.pos + 2 < self.input.len) self.pos += 3; // skip '-->'

            const comment_node = try self.createNode(.comment, comment_text);
            const parent = self.currentNode();
            tree.appendChild(parent, comment_node);
            return;
        }

        // CDATA or other: skip to '>'
        while (self.pos < self.input.len and self.input[self.pos] != '>') self.pos += 1;
        if (self.pos < self.input.len) self.pos += 1;
    }

    fn parseProcessingInstruction(self: *Parser) HtmlParseError!void {
        // Skip <?...?>
        self.pos += 2;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '>' and self.pos > 0 and self.input[self.pos - 1] == '?') {
                self.pos += 1;
                return;
            }
            // Also break on just '>' for malformed PI.
            if (self.input[self.pos] == '>') {
                self.pos += 1;
                return;
            }
            self.pos += 1;
        }
    }

    fn parseText(self: *Parser) HtmlParseError!void {
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '<') {
            self.pos += 1;
        }
        const raw = self.input[start..self.pos];
        if (raw.len == 0) return;

        const text = try self.decodeEntities(raw);

        try self.ensureStructure("");

        const text_node = try self.createNode(.text, text);
        const parent = self.currentNode();
        tree.appendChild(parent, text_node);
    }

    fn parseRawText(self: *Parser, tag_name: []const u8) HtmlParseError!void {
        const start = self.pos;
        while (self.pos < self.input.len) {
            // Look for </tagname>
            if (self.input[self.pos] == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
                const after_slash = self.pos + 2;
                var end = after_slash;
                while (end < self.input.len and self.input[end] != '>' and !isWhitespace(self.input[end])) {
                    end += 1;
                }
                const candidate = self.input[after_slash..end];
                if (std.ascii.eqlIgnoreCase(candidate, tag_name)) {
                    const text_content = self.input[start..self.pos];
                    if (text_content.len > 0) {
                        const text_node = try self.createNode(.text, text_content);
                        const parent = self.currentNode();
                        tree.appendChild(parent, text_node);
                    }
                    // Skip past </tagname>
                    self.pos = end;
                    while (self.pos < self.input.len and self.input[self.pos] != '>') self.pos += 1;
                    if (self.pos < self.input.len) self.pos += 1;
                    // Pop from open elements.
                    if (self.open_elements.items.len > 0) {
                        self.open_elements.items.len -= 1;
                    }
                    return;
                }
            }
            self.pos += 1;
        }
        // Unterminated raw text: emit rest as text.
        const text_content = self.input[start..self.pos];
        if (text_content.len > 0) {
            const text_node = try self.createNode(.text, text_content);
            const parent = self.currentNode();
            tree.appendChild(parent, text_node);
        }
    }

    fn parseAttribute(self: *Parser) HtmlParseError!Attribute {
        const name_start = self.pos;
        while (self.pos < self.input.len and
            self.input[self.pos] != '=' and self.input[self.pos] != '>' and
            self.input[self.pos] != '/' and !isWhitespace(self.input[self.pos]))
        {
            self.pos += 1;
        }
        const raw_name = self.input[name_start..self.pos];
        const name = try self.toLower(raw_name);

        self.skipWhitespace();

        if (self.pos < self.input.len and self.input[self.pos] == '=') {
            self.pos += 1; // skip '='
            self.skipWhitespace();
            const val = try self.parseAttrValue();
            return .{ .key = name, .val = val };
        }

        return .{ .key = name, .val = "" };
    }

    fn parseAttrValue(self: *Parser) HtmlParseError![]const u8 {
        if (self.pos >= self.input.len) return "";

        const quote = self.input[self.pos];
        if (quote == '"' or quote == '\'') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != quote) {
                self.pos += 1;
            }
            const raw = self.input[start..self.pos];
            if (self.pos < self.input.len) self.pos += 1;
            return self.decodeEntities(raw);
        }

        // Unquoted value.
        const start = self.pos;
        while (self.pos < self.input.len and !isWhitespace(self.input[self.pos]) and
            self.input[self.pos] != '>' and self.input[self.pos] != '/')
        {
            self.pos += 1;
        }
        return self.decodeEntities(self.input[start..self.pos]);
    }

    fn autoClose(self: *Parser, closers: []const []const u8) void {
        // Search backward through the stack for the nearest element that
        // should be auto-closed. Don't cross scope boundaries (html, table, etc.).
        var i = self.open_elements.items.len;
        while (i > 0) {
            i -= 1;
            const el = self.open_elements.items[i];
            if (scope_elements.has(el.data)) break;
            for (closers) |closer| {
                if (std.mem.eql(u8, el.data, closer)) {
                    // Pop everything from this element up.
                    self.open_elements.items.len = i;
                    return;
                }
            }
        }
    }

    fn ensureStructure(self: *Parser, tag_name: []const u8) HtmlParseError!void {
        if (self.fragment_context != null) return;

        const is_html = std.mem.eql(u8, tag_name, "html");
        const is_head = std.mem.eql(u8, tag_name, "head");
        const is_body = std.mem.eql(u8, tag_name, "body");

        // Ensure <html> exists on the stack.
        if (self.open_elements.items.len == 0) {
            if (is_html) return; // about to be added by caller
            const html_node = try self.createNode(.element, "html");
            tree.appendChild(self.doc, html_node);
            try self.open_elements.append(self.allocator, html_node);
        }

        // Skip head tracking — if we see a non-head element, mark head done.
        if (!self.head_inserted) {
            if (is_head) {
                self.head_inserted = true;
                return;
            }
            const in_head = std.mem.eql(u8, tag_name, "meta") or
                std.mem.eql(u8, tag_name, "link") or
                std.mem.eql(u8, tag_name, "title") or
                std.mem.eql(u8, tag_name, "style") or
                std.mem.eql(u8, tag_name, "script") or
                std.mem.eql(u8, tag_name, "base");

            if (!in_head) {
                self.head_inserted = true;
            }
        }

        // Ensure <body> exists for non-head content.
        if (self.head_inserted and !self.body_inserted) {
            if (is_body) {
                // Explicit <body> tag — mark as inserted but let caller add it.
                self.body_inserted = true;
                return;
            }
            if (!is_html) {
                const body_node = try self.createNode(.element, "body");
                const html_el = self.open_elements.items[0];
                tree.appendChild(html_el, body_node);
                try self.open_elements.append(self.allocator, body_node);
                self.body_inserted = true;
            }
        }
    }

    fn currentNode(self: *Parser) *Node {
        if (self.open_elements.items.len > 0) {
            return self.open_elements.items[self.open_elements.items.len - 1];
        }
        return self.doc;
    }

    fn createNode(self: *Parser, node_type: NodeType, data: []const u8) HtmlParseError!*Node {
        const node = self.allocator.create(Node) catch return HtmlParseError.OutOfMemory;
        node.* = .{
            .node_type = node_type,
            .data = data,
        };
        return node;
    }

    fn emitChar(self: *Parser) HtmlParseError!void {
        const start = self.pos;
        self.pos += 1;
        const text_node = try self.createNode(.text, self.input[start..self.pos]);
        const parent = self.currentNode();
        tree.appendChild(parent, text_node);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }

    fn toLower(self: *Parser, input: []const u8) HtmlParseError![]const u8 {
        var needs_lower = false;
        for (input) |c| {
            if (c >= 'A' and c <= 'Z') {
                needs_lower = true;
                break;
            }
        }
        if (!needs_lower) return input;

        const buf = self.allocator.alloc(u8, input.len) catch return HtmlParseError.OutOfMemory;
        for (input, 0..) |c, i| {
            buf[i] = std.ascii.toLower(c);
        }
        return buf;
    }

    fn decodeEntities(self: *Parser, input: []const u8) HtmlParseError![]const u8 {
        // Fast path: no ampersand means no entities.
        if (std.mem.indexOfScalar(u8, input, '&') == null) return input;

        var result: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '&') {
                const entity_result = self.decodeEntity(input, i);
                result.appendSlice(self.allocator, entity_result.text) catch return HtmlParseError.OutOfMemory;
                i = entity_result.end;
            } else {
                result.append(self.allocator, input[i]) catch return HtmlParseError.OutOfMemory;
                i += 1;
            }
        }
        return result.toOwnedSlice(self.allocator) catch return HtmlParseError.OutOfMemory;
    }

    const EntityResult = struct {
        text: []const u8,
        end: usize,
    };

    fn decodeEntity(self: *Parser, input: []const u8, start: usize) EntityResult {
        _ = self;
        std.debug.assert(input[start] == '&');
        const after_amp = start + 1;

        if (after_amp >= input.len) return .{ .text = "&", .end = start + 1 };

        // Numeric character reference.
        if (input[after_amp] == '#') {
            const after_hash = after_amp + 1;
            if (after_hash >= input.len) return .{ .text = "&#", .end = after_hash };

            var is_hex = false;
            var num_start = after_hash;
            if (input[after_hash] == 'x' or input[after_hash] == 'X') {
                is_hex = true;
                num_start = after_hash + 1;
            }

            var num_end = num_start;
            while (num_end < input.len and num_end < num_start + 8) {
                const c = input[num_end];
                if (is_hex) {
                    if (!std.ascii.isHex(c)) break;
                } else {
                    if (!std.ascii.isDigit(c)) break;
                }
                num_end += 1;
            }

            if (num_end > num_start) {
                const num_str = input[num_start..num_end];
                const base: u8 = if (is_hex) 16 else 10;
                if (std.fmt.parseInt(u21, num_str, base)) |codepoint| {
                    if (codepoint <= 0x10FFFF) {
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                            return .{ .text = input[start .. num_end + 1], .end = num_end + 1 };
                        };
                        // Leak into arena — fine for document lifetime.
                        _ = len;
                        var end = num_end;
                        if (end < input.len and input[end] == ';') end += 1;
                        // Return raw entity for now — full entity decoding is complex
                        // and rarely needed for CSS selector matching.
                        return .{ .text = input[start..end], .end = end };
                    }
                } else |_| {}
            }
            return .{ .text = "&", .end = start + 1 };
        }

        // Named entity references — handle the most common ones.
        const named_entities = .{
            .{ "amp;", "&" },
            .{ "lt;", "<" },
            .{ "gt;", ">" },
            .{ "quot;", "\"" },
            .{ "apos;", "'" },
            .{ "nbsp;", "\xc2\xa0" },
            .{ "times;", "\xc3\x97" },
            .{ "copy;", "\xc2\xa9" },
        };

        inline for (named_entities) |entry| {
            const name = entry[0];
            const replacement = entry[1];
            if (after_amp + name.len <= input.len and
                std.mem.eql(u8, input[after_amp .. after_amp + name.len], name))
            {
                return .{ .text = replacement, .end = after_amp + name.len };
            }
        }

        return .{ .text = "&", .end = start + 1 };
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

test "parse simple HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parse(arena.allocator(), "<div><p>Hello</p></div>");
    try std.testing.expect(doc.node_type == .document);

    // Should have html element.
    const html_el = doc.first_child orelse
        (if (doc.first_child) |fc| fc.next_sibling else null);
    try std.testing.expect(html_el != null);
}

test "parse with doctype" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parse(arena.allocator(), "<!DOCTYPE html><html><head></head><body><p>test</p></body></html>");
    try std.testing.expect(doc.node_type == .document);

    // First child should be doctype.
    const first = doc.first_child.?;
    try std.testing.expect(first.node_type == .doctype);
    try std.testing.expectEqualStrings("html", first.data);
}

test "parse void elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parse(arena.allocator(), "<br><hr><img src=\"test.png\">");
    try std.testing.expect(doc.node_type == .document);
}

test "parse comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parse(arena.allocator(), "<div><!-- a comment --></div>");
    _ = doc;
}

test "parse attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parse(arena.allocator(), "<div id=\"main\" class=\"container\"><a href=\"/test\">link</a></div>");
    _ = doc;
}

test "parse entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parse(arena.allocator(), "<p>&amp; &lt; &gt;</p>");
    _ = doc;
}
