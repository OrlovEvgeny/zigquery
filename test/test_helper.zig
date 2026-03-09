const std = @import("std");
const zq = @import("zigquery");

/// Parse HTML into a Document using the testing allocator.
pub fn parseDoc(html: []const u8) !zq.Document {
    return zq.Document.initFromSlice(std.testing.allocator, html);
}

pub const page_html = @embedFile("testdata/page.html");
pub const page2_html = @embedFile("testdata/page2.html");
pub const page3_html = @embedFile("testdata/page3.html");
