//! Deterministic synthetic HTML generation for benchmarking.
//!
//! Nothing here touches the filesystem or the clock: the same `Shape` always
//! produces the same bytes, so a benchmark number from one machine is
//! comparable with one from another. The random source is written out by hand
//! rather than taken from `std.Random`, whose algorithms are free to change
//! between Zig releases.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// xorshift64. Stable by construction.
const Rng = struct {
    state: u64,

    fn init(seed: u64) Rng {
        return .{ .state = if (seed == 0) 0x9E3779B97F4A7C15 else seed };
    }

    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }

    fn below(self: *Rng, n: u32) u32 {
        std.debug.assert(n > 0);
        return @intCast(self.next() % n);
    }

    fn chance(self: *Rng, percent: u32) bool {
        return self.below(100) < percent;
    }
};

/// Container elements the generator nests. `div` is weighted heavily so that
/// `div.row` selectors have a realistic amount of chaff to walk past.
const containers = [_][]const u8{
    "div", "div", "div", "section", "ul", "li", "p", "article", "span", "td",
};

/// Leaf elements. `a` is present so `div.row a.link` and `:has(> a)` have
/// something to match.
const leaves = [_][]const u8{ "a", "span", "em", "strong", "code", "b" };

/// Short tags for the `minimal_markup` shape.
const terse_containers = [_][]const u8{ "div", "p", "li", "td", "b", "i", "u", "s" };
const terse_leaves = [_][]const u8{ "a", "i", "b", "u" };

const short_words = [_][]const u8{ "ab", "cd", "ef", "gh", "ij", "kl", "mn", "op" };

const words = [_][]const u8{
    "alpha",  "bravo",    "charlie", "delta",  "echo",    "foxtrot",
    "golf",   "hotel",    "india",   "juliet", "kilo",    "lima",
    "mike",   "november", "oscar",   "papa",   "quebec",  "romeo",
    "sierra", "tango",    "uniform", "victor", "whiskey", "xray",
};

const attr_keys = [_][]const u8{
    "id", "data-id", "data-role", "title", "rel", "lang", "data-index",
};

pub const Shape = struct {
    /// Generation stops once the buffer passes this size; the result is
    /// approximately, not exactly, this many bytes.
    target_bytes: usize,
    max_depth: u32 = 12,
    /// Percent chance of descending rather than closing the current element.
    descend_percent: u32 = 55,
    attrs_per_el: u32 = 2,
    /// Number of distinct class names in circulation. A small pool makes class
    /// selectors match often; a large one makes them selective.
    class_pool: u32 = 24,
    /// Percent of elements that get a text child.
    text_percent: u32 = 45,
    /// Percent of text runs that carry a character reference.
    entity_percent: u32 = 0,
    /// Emit a `<script>` block every N elements. 0 disables.
    script_every: u32 = 0,
    /// Drop class and href attributes and use one-letter tags. Produces a
    /// document with many nodes per kilobyte, which is the shape that stresses
    /// per-node cost rather than per-byte cost.
    minimal_markup: bool = false,
    seed: u64 = 0x9E3779B97F4A7C15,
};

pub const Preset = struct {
    name: []const u8,
    shape: Shape,
};

pub const presets = [_]Preset{
    .{ .name = "small", .shape = .{ .target_bytes = 64 << 10 } },
    // Sized to match the 2.2 MB / ~160k node document the v0.3 targets were
    // measured against.
    .{ .name = "medium", .shape = .{ .target_bytes = 2_200_000 } },
    .{ .name = "large", .shape = .{ .target_bytes = 10 << 20 } },
    .{ .name = "attr_heavy", .shape = .{
        .target_bytes = 2_200_000,
        .attrs_per_el = 8,
        .class_pool = 200,
        .text_percent = 10,
    } },
    .{ .name = "entity_heavy", .shape = .{
        .target_bytes = 2_200_000,
        .text_percent = 90,
        .entity_percent = 70,
    } },
    .{ .name = "script_heavy", .shape = .{
        .target_bytes = 2_200_000,
        .script_every = 40,
    } },
    // ~14 bytes of input per node, matching the document the v0.3 memory and
    // parse targets were originally measured against.
    .{ .name = "dense", .shape = .{
        .target_bytes = 2_200_000,
        .minimal_markup = true,
        .attrs_per_el = 0,
        .max_depth = 20,
        .descend_percent = 50,
        .text_percent = 85,
    } },
    .{ .name = "shallow_wide", .shape = .{
        .target_bytes = 2_200_000,
        .max_depth = 3,
        .descend_percent = 15,
    } },
};

pub fn presetByName(name: []const u8) ?Shape {
    for (presets) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.shape;
    }
    return null;
}

/// Build a document matching `shape`. Caller owns the result.
pub fn generate(gpa: Allocator, shape: Shape) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    // Slight over-reserve: closing the open element stack overshoots the target.
    try buf.ensureTotalCapacity(gpa, shape.target_bytes + 4096);

    var rng = Rng.init(shape.seed);
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(gpa);

    try buf.appendSlice(gpa,
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8"><title>bench corpus</title></head><body>
        \\
    );

    var elements: u64 = 0;
    while (buf.items.len < shape.target_bytes) {
        const depth: u32 = @intCast(stack.items.len);

        // Close if we are as deep as allowed, or if the dice say so. Always
        // descend from the root so the loop cannot spin without emitting.
        if (depth > 0 and (depth >= shape.max_depth or !rng.chance(shape.descend_percent))) {
            try closeTop(gpa, &buf, &stack);
            continue;
        }

        if (shape.script_every > 0 and elements % shape.script_every == shape.script_every - 1) {
            try buf.appendSlice(gpa,
                \\<script>var x = 1; if (x < 2 && x > 0) { x = x + 1; }</script>
            );
        }

        const tag = if (shape.minimal_markup)
            terse_containers[rng.below(terse_containers.len)]
        else
            containers[rng.below(containers.len)];
        try openTag(gpa, &buf, &rng, shape, tag, depth);
        try stack.append(gpa, tag);
        elements += 1;

        if (rng.chance(shape.text_percent)) {
            try emitText(gpa, &buf, &rng, shape);
        }

        // Leaves are emitted inline and closed immediately, which is what
        // gives `div.row > a.link` and `:has(> a)` their match sets.
        if (rng.chance(35)) {
            const leaf = if (shape.minimal_markup)
                terse_leaves[rng.below(terse_leaves.len)]
            else
                leaves[rng.below(leaves.len)];
            try openTag(gpa, &buf, &rng, shape, leaf, depth + 1);
            try emitText(gpa, &buf, &rng, shape);
            try buf.appendSlice(gpa, "</");
            try buf.appendSlice(gpa, leaf);
            try buf.append(gpa, '>');
            elements += 1;
        }
    }

    while (stack.items.len > 0) try closeTop(gpa, &buf, &stack);
    try buf.appendSlice(gpa, "</body></html>\n");

    return buf.toOwnedSlice(gpa);
}

fn closeTop(gpa: Allocator, buf: *std.ArrayList(u8), stack: *std.ArrayList([]const u8)) !void {
    const tag = stack.pop().?;
    try buf.appendSlice(gpa, "</");
    try buf.appendSlice(gpa, tag);
    try buf.append(gpa, '>');
}

fn openTag(
    gpa: Allocator,
    buf: *std.ArrayList(u8),
    rng: *Rng,
    shape: Shape,
    tag: []const u8,
    depth: u32,
) !void {
    try buf.append(gpa, '<');
    try buf.appendSlice(gpa, tag);

    if (shape.minimal_markup) {
        // Keep just enough classes for `.row` / `.link` selectors to have a
        // match set, but spend no bytes on anything else.
        if (std.mem.eql(u8, tag, "div") and rng.chance(30)) {
            try buf.appendSlice(gpa, " class=row");
        } else if (std.mem.eql(u8, tag, "a") and rng.chance(60)) {
            try buf.appendSlice(gpa, " class=link");
        }
        try buf.append(gpa, '>');
        return;
    }

    try buf.appendSlice(gpa, " class=\"");
    // `row` on divs and `link` on anchors are the selectors the benchmarks
    // target; the pooled classes surround them with realistic noise.
    if (std.mem.eql(u8, tag, "div") and rng.chance(30)) {
        try buf.appendSlice(gpa, "row ");
    } else if (std.mem.eql(u8, tag, "a") and rng.chance(60)) {
        try buf.appendSlice(gpa, "link ");
    }
    try buf.appendSlice(gpa, "c");
    try printInt(gpa, buf, rng.below(shape.class_pool));
    if (rng.chance(40)) {
        try buf.appendSlice(gpa, " d");
        try printInt(gpa, buf, rng.below(shape.class_pool));
    }
    try buf.append(gpa, '"');

    if (std.mem.eql(u8, tag, "a")) {
        try buf.appendSlice(gpa, " href=\"/p/");
        try printInt(gpa, buf, rng.below(100000));
        try buf.append(gpa, '"');
    }

    var i: u32 = 0;
    while (i < shape.attrs_per_el) : (i += 1) {
        const key = attr_keys[rng.below(attr_keys.len)];
        try buf.append(gpa, ' ');
        try buf.appendSlice(gpa, key);
        try buf.appendSlice(gpa, "=\"");
        try buf.appendSlice(gpa, words[rng.below(words.len)]);
        try buf.append(gpa, '-');
        try printInt(gpa, buf, depth * 1000 + rng.below(1000));
        try buf.append(gpa, '"');
    }

    try buf.append(gpa, '>');
}

fn emitText(gpa: Allocator, buf: *std.ArrayList(u8), rng: *Rng, shape: Shape) !void {
    if (shape.minimal_markup) {
        try buf.appendSlice(gpa, short_words[rng.below(short_words.len)]);
        return;
    }
    const count = 1 + rng.below(5);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try buf.append(gpa, ' ');
        try buf.appendSlice(gpa, words[rng.below(words.len)]);
    }
    if (shape.entity_percent > 0 and rng.chance(shape.entity_percent)) {
        try buf.appendSlice(gpa, " &amp; &lt;tag&gt; &#8212; &nbsp;");
    }
}

fn printInt(gpa: Allocator, buf: *std.ArrayList(u8), value: u32) !void {
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    try buf.appendSlice(gpa, s);
}

/// `count` nested `<div>` elements. This is the shape that overflows the stack
/// in every recursive traversal in the library.
pub fn generateNested(gpa: Allocator, count: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.ensureTotalCapacity(gpa, @as(usize, count) * 12 + 128);

    try buf.appendSlice(gpa, "<html><body>");
    var i: u32 = 0;
    while (i < count) : (i += 1) try buf.appendSlice(gpa, "<div class=\"n\">");
    try buf.appendSlice(gpa, "<a class=\"link\" href=\"/deep\">bottom</a>");
    i = 0;
    while (i < count) : (i += 1) try buf.appendSlice(gpa, "</div>");
    try buf.appendSlice(gpa, "</body></html>");

    return buf.toOwnedSlice(gpa);
}

/// `count` siblings under a single parent. Exercises the sibling scans in
/// `:nth-child` and friends, which are quadratic today.
pub fn generateWide(gpa: Allocator, count: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.ensureTotalCapacity(gpa, @as(usize, count) * 40 + 128);

    try buf.appendSlice(gpa, "<html><body><div class=\"row\">");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try buf.appendSlice(gpa, "<span class=\"cell c");
        try printInt(gpa, &buf, i % 16);
        try buf.appendSlice(gpa, "\">x</span>");
    }
    try buf.appendSlice(gpa, "</div></body></html>");

    return buf.toOwnedSlice(gpa);
}

test "generate is deterministic and hits its target size" {
    const gpa = std.testing.allocator;
    const shape: Shape = .{ .target_bytes = 200_000 };

    const a = try generate(gpa, shape);
    defer gpa.free(a);
    const b = try generate(gpa, shape);
    defer gpa.free(b);

    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expect(a.len >= shape.target_bytes);
    // The overshoot is only the closing tags for the open element stack.
    try std.testing.expect(a.len < shape.target_bytes + 4096);
}

test "generate emits the selector targets the benchmarks use" {
    const gpa = std.testing.allocator;
    const html = try generate(gpa, .{ .target_bytes = 200_000 });
    defer gpa.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"row ") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"link ") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/p/") != null);
}

test "every preset generates" {
    const gpa = std.testing.allocator;
    for (presets) |p| {
        // Keep the test fast: shrink the big presets but keep their character.
        var shape = p.shape;
        shape.target_bytes = @min(shape.target_bytes, 120_000);
        const html = try generate(gpa, shape);
        defer gpa.free(html);
        try std.testing.expect(html.len >= shape.target_bytes);
    }
}

test "nested and wide generators" {
    const gpa = std.testing.allocator;

    const nested = try generateNested(gpa, 1000);
    defer gpa.free(nested);
    try std.testing.expectEqual(@as(usize, 1000), std.mem.count(u8, nested, "<div"));
    try std.testing.expectEqual(@as(usize, 1000), std.mem.count(u8, nested, "</div>"));

    const wide = try generateWide(gpa, 1000);
    defer gpa.free(wide);
    try std.testing.expectEqual(@as(usize, 1000), std.mem.count(u8, wide, "<span"));
}
