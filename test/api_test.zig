const std = @import("std");
const zq = @import("zigquery");

fn keepAll(_: usize, _: zq.Selection) bool {
    return true;
}

const universal_selector = zq.Selector{ .universal = {} };

test "allocating selection APIs propagate errors" {
    var doc = try zq.Document.initFromSlice(
        std.testing.allocator,
        "<main><div><p>A</p><span>B</span></div><div><p>C</p></div></main>",
    );
    defer doc.deinit();

    var compiled = try zq.CompiledSelector.init(std.testing.allocator, "p");
    defer compiled.deinit();
    const matcher = compiled.matcher(doc.allocator());

    const divs = try doc.find("div");
    const paragraphs = try doc.find("p");
    _ = try divs.findMatcher(matcher);
    _ = try divs.findSelection(paragraphs);
    _ = try divs.findNodes(paragraphs.nodes);
    _ = try divs.childrenMatcher(matcher);
    _ = try divs.contentsFiltered("p");
    _ = try paragraphs.parentMatcher(matcher);
    _ = try paragraphs.parentsMatcher(matcher);
    _ = try paragraphs.parentsUntil(.{ .until = matcher });
    _ = try paragraphs.closestNodes(divs.nodes);
    _ = try paragraphs.closestSelection(divs);
    _ = try paragraphs.siblingsMatcher(matcher);
    _ = try paragraphs.nextMatcher(matcher);
    _ = try paragraphs.nextAllMatcher(matcher);
    _ = try paragraphs.nextUntil(.{ .filter = matcher });
    _ = try paragraphs.prevMatcher(matcher);
    _ = try paragraphs.prevAllMatcher(matcher);
    _ = try paragraphs.prevUntil(.{ .filter = matcher });
    _ = try paragraphs.filterMatcher(matcher);
    _ = try paragraphs.filterFn(keepAll);
    _ = try paragraphs.filterNodes(paragraphs.nodes);
    _ = try paragraphs.filterSelection(paragraphs);
    _ = try paragraphs.notMatcher(matcher);
    _ = try paragraphs.notFn(keepAll);
    _ = try paragraphs.notNodes(paragraphs.nodes);
    _ = try paragraphs.notSelection(paragraphs);
    _ = try divs.hasMatcher(matcher);
    _ = try divs.hasNodes(paragraphs.nodes);
    _ = try divs.hasSelection(paragraphs);
    _ = try paragraphs.indexOfMatcher(matcher);
    _ = try paragraphs.addMatcher(matcher);
    _ = try paragraphs.addSelection(divs);
    _ = try paragraphs.addNodes(divs.nodes);
    _ = try paragraphs.@"union"(divs);
    _ = try (try divs.children()).addBack();
    _ = try (try divs.children()).addBackFiltered("div");
}

test "node mutation APIs compile and preserve invariants" {
    var doc = try zq.Document.initFromSlice(std.testing.allocator, "<main><div><p>A</p></div></main>");
    defer doc.deinit();
    var source = try zq.Document.initFromSlice(std.testing.allocator, "<i>x</i>");
    defer source.deinit();

    const empty = try doc.find("missing");
    const source_nodes = try source.find("i");
    try empty.afterNodes(source_nodes.nodes);
    try empty.beforeNodes(source_nodes.nodes);
    try empty.appendNodes(source_nodes.nodes);
    try empty.prependNodes(source_nodes.nodes);
    _ = try empty.replaceWithNodes(source_nodes.nodes);
    _ = try empty.removeMatcher(compiledMatcher(&doc));
    try empty.wrapNode(source_nodes.nodes[0]);
    try empty.wrapAllNode(source_nodes.nodes[0]);
    try empty.wrapInnerNode(source_nodes.nodes[0]);
    try zq.tree.validate(std.testing.allocator, doc.root_node);
}

fn compiledMatcher(doc: *zq.Document) zq.Matcher {
    return zq.Matcher.init(doc.allocator(), &universal_selector);
}
