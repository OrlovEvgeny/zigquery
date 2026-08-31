const std = @import("std");
const zq = @import("zigquery");

test "compiled selector is owning and reusable across documents" {
    const source = try std.testing.allocator.dupe(u8, "li.active");
    var compiled = try zq.CompiledSelector.init(std.testing.allocator, source);
    std.testing.allocator.free(source);
    defer compiled.deinit();

    var first = try zq.Document.initFromSlice(std.testing.allocator, "<ul><li class=active>A</li><li>B</li></ul>");
    defer first.deinit();
    var q_first = first.query(std.testing.allocator);
    defer q_first.deinit();
    var second = try zq.Document.initFromSlice(std.testing.allocator, "<li class=active>C</li>");
    defer second.deinit();
    var q_second = second.query(std.testing.allocator);
    defer q_second.deinit();

    try std.testing.expect((try q_first.findCompiled(&compiled)).len() == 1);
    try std.testing.expect((try q_second.findCompiled(&compiled)).len() == 1);

    const all = try q_first.find("li");
    const filtered = try all.filterCompiled(&compiled);
    try std.testing.expect(filtered.len() == 1);
    try std.testing.expect(filtered.isCompiled(&compiled));
}
