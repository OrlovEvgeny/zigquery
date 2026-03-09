//! zigquery — jQuery-like HTML DOM querying and manipulation for Zig.
//!
//! Parse HTML, query with CSS selectors, traverse, filter, and manipulate the DOM.
//!
//! ```zig
//! const zq = @import("zigquery");
//! var doc = try zq.Document.initFromSlice(allocator, html);
//! defer doc.deinit();
//! const links = try doc.find("a.active");
//! for (links.nodes) |node| {
//!     std.debug.print("href={s}\n", .{node.getAttr("href") orelse ""});
//! }
//! ```

pub const Document = @import("document.zig").Document;
pub const Selection = @import("selection.zig").Selection;
pub const outerHtml = @import("selection.zig").outerHtml;
pub const nodeName = @import("selection.zig").nodeName;

pub const Node = @import("dom/node.zig").Node;
pub const NodeType = @import("dom/node.zig").NodeType;
pub const Attribute = @import("dom/node.zig").Attribute;

pub const tree = @import("dom/tree.zig");
pub const html_parser = @import("dom/parser.zig");
pub const html_render = @import("dom/render.zig");

pub const Selector = @import("css/selector.zig").Selector;
pub const css_parser = @import("css/parser.zig");
pub const Matcher = @import("css/matcher.zig").Matcher;
pub const CssParseError = @import("css/parser.zig").CssParseError;

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
