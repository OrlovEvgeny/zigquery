//! zigquery benchmark driver.
//!
//!   zig build bench                     -- the standard suite
//!   zig build bench -- --filter find    -- only benchmarks whose name matches
//!   zig build bench -- --json out.json  -- machine-readable results
//!   zig build bench -- --scaling        -- report empirical complexity
//!   zig build bench -- --corpus <dir>   -- also run against local .html files
//!   zig build bench -- --deep           -- include the deep-nesting suite
//!
//! The deep suite is opt-in because it builds documents up to 50 000 levels
//! deep and 100 000 siblings wide, which takes a moment even now that the
//! quadratic paths are gone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zq = @import("zigquery");
const corpus = @import("corpus.zig");
const harness = @import("harness.zig");
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;

const Stats = harness.Stats;

const Config = struct {
    filter: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    corpus_dir: ?[]const u8 = null,
    scaling: bool = false,
    deep: bool = false,
    /// Shrink the corpora so a full run takes seconds. For smoke-testing the
    /// harness itself, not for producing a baseline.
    quick: bool = false,
    /// Fail the process when a gate is violated. This is what CI runs.
    strict: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const config = parseArgs(argv) catch {
        std.debug.print("{s}\n", .{usage});
        return;
    };

    var counting = CountingAllocator.init(gpa);

    var runner: Runner = .{
        .gpa = gpa,
        .measured = counting.allocator(),
        .counting = &counting,
        .io = io,
        .config = config,
    };
    defer runner.deinit();

    try runner.runAll();
    try runner.report();

    if (config.strict and runner.violations > 0) {
        std.debug.print("\n{d} gate violation(s)\n", .{runner.violations});
        return error.BenchmarkGateFailed;
    }
}

const usage =
    \\usage: bench [options]
    \\  --filter <substr>   only run benchmarks whose name contains <substr>
    \\  --json <path>       write results as JSON
    \\  --corpus <dir>      also benchmark every .html file in <dir>
    \\  --scaling           report the empirical complexity exponent
    \\  --deep              include the deep-nesting suite (may abort)
    \\  --quick             shrink corpora for a fast smoke run
    \\  --strict            exit non-zero if a gate is violated (for CI)
    \\
    \\Gates checked by --strict:
    \\  * no benchmark may grow the document arena
    \\  * no workload may exceed the superlinear scaling threshold
;

fn parseArgs(argv: []const [:0]const u8) !Config {
    var config: Config = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            config.filter = argv[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            config.json_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            config.corpus_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--scaling")) {
            config.scaling = true;
        } else if (std.mem.eql(u8, arg, "--deep")) {
            config.deep = true;
        } else if (std.mem.eql(u8, arg, "--quick")) {
            config.quick = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            config.strict = true;
        } else {
            return error.Usage;
        }
    }
    return config;
}

// ---------------------------------------------------------------------------
// Benchmark contexts
// ---------------------------------------------------------------------------

/// Parse and immediately release, so `peak_bytes` measures the cost of holding
/// one parsed document.
const ParseCtx = struct {
    alloc: Allocator,
    html: []const u8,

    fn step(self: *ParseCtx) !void {
        var doc = try zq.Document.initFromSlice(self.alloc, self.html);
        defer doc.deinit();
        std.mem.doNotOptimizeAway(doc.root_node);
    }
};

const FindCtx = struct {
    q: *zq.Query,
    selector: []const u8,
    sink: usize = 0,

    fn step(self: *FindCtx) !void {
        const sel = try self.q.find(self.selector);
        self.sink = sel.len();
        std.mem.doNotOptimizeAway(&self.sink);
    }
};

const RenderCtx = struct {
    alloc: Allocator,
    doc: *zq.Document,

    fn step(self: *RenderCtx) !void {
        const html = try zq.html_render.renderToString(self.alloc, self.doc.root_node);
        defer self.alloc.free(html);
        std.mem.doNotOptimizeAway(html.ptr);
    }
};

const CloneCtx = struct {
    alloc: Allocator,
    doc: *zq.Document,

    fn step(self: *CloneCtx) !void {
        var copy = try self.doc.clone(self.alloc);
        defer copy.deinit();
        std.mem.doNotOptimizeAway(copy.root_node);
    }
};

const TextCtx = struct {
    q: *zq.Query,
    sink: usize = 0,

    fn step(self: *TextCtx) !void {
        const sel = try self.q.find("body");
        const text = try sel.text();
        self.sink = text.len;
        std.mem.doNotOptimizeAway(&self.sink);
    }
};

/// Traversal benchmarks share this shape: take a starting selection and walk
/// somewhere from it.
const TraverseCtx = struct {
    q: *zq.Query,
    base: zq.Selection,
    kind: Kind,
    sink: usize = 0,

    const Kind = enum { children, parent, siblings, next_all, filter, first };

    fn step(self: *TraverseCtx) !void {
        const out = switch (self.kind) {
            .children => try self.base.children(),
            .parent => try self.base.parent(),
            .siblings => try self.base.siblings(),
            .next_all => try self.base.nextAll(),
            .filter => try self.base.filter(".row"),
            .first => try self.base.first(),
        };
        self.sink = out.len();
        std.mem.doNotOptimizeAway(&self.sink);
    }
};

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

const Runner = struct {
    gpa: Allocator,
    /// The allocator handed to the library, wrapped so every request is counted.
    measured: Allocator,
    counting: *CountingAllocator,
    io: Io,
    config: Config,
    results: std.ArrayList(Stats) = .empty,
    /// Benchmark names outlive the loop that creates them.
    names: std.ArrayList([]u8) = .empty,
    scaling_rows: std.ArrayList(ScalingRow) = .empty,
    /// Gate failures seen so far; `--strict` turns these into a non-zero exit.
    violations: u32 = 0,

    const ScalingRow = struct {
        name: []const u8,
        exponent: f64,
        ns: [3]u64,
    };

    fn deinit(self: *Runner) void {
        for (self.names.items) |n| self.gpa.free(n);
        self.names.deinit(self.gpa);
        self.results.deinit(self.gpa);
        self.scaling_rows.deinit(self.gpa);
    }

    fn wanted(self: *Runner, name: []const u8) bool {
        const f = self.config.filter orelse return true;
        return std.mem.indexOf(u8, name, f) != null;
    }

    fn own(self: *Runner, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const s = try std.fmt.allocPrint(self.gpa, fmt, args);
        try self.names.append(self.gpa, s);
        return s;
    }

    fn add(self: *Runner, s: Stats) !void {
        try self.results.append(self.gpa, s);
        // Print as we go: a full run takes a while and the reader should not
        // have to wait for the last benchmark to see the first result.
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        try harness.writeRow(self.gpa, &line, s);
        std.debug.print("{s}", .{line.items});
    }

    /// Measure a benchmark that queries a live document, reporting how much
    /// that document's own arena grew per operation.
    ///
    /// The counting allocator sits *below* the arena and only observes chunk
    /// requests, so an operation that fits in a chunk's spare capacity looks
    /// free to it. The arena's own capacity is the honest number, and it is
    /// the one that matches "the arena went from 27 MB to 261 MB".
    fn measureOnDocument(
        self: *Runner,
        name: []const u8,
        doc: *zq.Document,
        q: *zq.Query,
        opts: harness.Options,
        ctx: anytype,
        comptime step: fn (@TypeOf(ctx)) anyerror!void,
    ) !Stats {
        const doc_before = doc.arena.queryCapacity();
        const q_before = q.bytesUsed();
        var stats = try harness.measure(name, self.io, self.counting, opts, ctx, step);

        // Query-arena growth is expected: that arena is the scratch space, and
        // it is reclaimed wholesale by `deinit`/`reset`. It is reported so the
        // per-operation cost is visible, not as a failure.
        stats.growth_per_op = (q.bytesUsed() -| q_before) / @max(stats.iters, 1);
        // Document growth from a read-only query is the actual defect.
        stats.doc_grew = doc.arena.queryCapacity() > doc_before;
        return stats;
    }

    fn scale(self: *Runner, bytes: usize) usize {
        return if (self.config.quick) @min(bytes, 150_000) else bytes;
    }

    fn runAll(self: *Runner) !void {
        var header: std.ArrayList(u8) = .empty;
        defer header.deinit(self.gpa);
        try harness.writeHeader(self.gpa, &header);
        std.debug.print("{s}", .{header.items});

        try self.runParseSuite();
        try self.runQuerySuite();
        try self.runLeakGate();
        try self.runDocumentSuite();
        if (self.config.deep) try self.runDeepSuite();
        if (self.config.corpus_dir) |dir| try self.runCorpusDir(dir);
        if (self.config.scaling) try self.runScaling();
    }

    fn runParseSuite(self: *Runner) !void {
        for (corpus.presets) |preset| {
            const name = try self.own("parse/{s}", .{preset.name});
            if (!self.wanted(name)) continue;

            var shape = preset.shape;
            shape.target_bytes = self.scale(shape.target_bytes);
            const html = try corpus.generate(self.gpa, shape);
            defer self.gpa.free(html);

            var ctx: ParseCtx = .{ .alloc = self.measured, .html = html };
            var stats = try harness.measure(name, self.io, self.counting, .{}, &ctx, ParseCtx.step);
            stats.bytes_in = html.len;
            try self.add(stats);
        }
    }

    const selectors = [_]struct { name: []const u8, sel: []const u8 }{
        .{ .name = "find/tag", .sel = "span" },
        .{ .name = "find/class", .sel = ".row" },
        .{ .name = "find/compound", .sel = "a.link" },
        .{ .name = "find/descendant", .sel = "div.row a.link" },
        .{ .name = "find/child", .sel = "div.row > a.link" },
        .{ .name = "find/attr_exists", .sel = "[data-role]" },
        .{ .name = "find/attr_prefix", .sel = "[href^=\"/p/1\"]" },
        .{ .name = "find/nth_child", .sel = "li:nth-child(2n+1)" },
        .{ .name = "find/has_child", .sel = "div:has(> a)" },
        .{ .name = "find/has_descendant", .sel = "div:has(a.link)" },
        .{ .name = "find/contains", .sel = "p:contains(\"alpha\")" },
        .{ .name = "find/group", .sel = "span.c1, p.c2, a.link" },
        .{ .name = "find/not", .sel = "a:not(.link)" },
        .{ .name = "find/universal", .sel = "*" },
    };

    fn runQuerySuite(self: *Runner) !void {
        var shape = corpus.presetByName("medium").?;
        shape.target_bytes = self.scale(shape.target_bytes);
        const html = try corpus.generate(self.gpa, shape);
        defer self.gpa.free(html);

        for (selectors) |entry| {
            if (!self.wanted(entry.name)) continue;

            // A fresh document per selector: every query permanently retains
            // memory in the document arena today, so sharing one document
            // across the suite would make later benchmarks measure a
            // progressively more fragmented arena.
            var doc = try zq.Document.initFromSlice(self.measured, html);
            defer doc.deinit();
            var q = doc.query(self.measured);
            defer q.deinit();

            var ctx: FindCtx = .{ .q = &q, .selector = entry.sel };
            const stats = try self.measureOnDocument(entry.name, &doc, &q, .{
                .max_growth_bytes = 256 << 20,
                // `:has()` currently takes about a second per call on this
                // corpus, so a single sample has to be acceptable.
                .warmup_iters = 1,
            }, &ctx, FindCtx.step);
            try self.add(stats);
        }
    }

    /// The headline regression: repeated queries against one document must not
    /// grow it. Measured directly rather than through the sampling loop, so
    /// the number is exactly "bytes the document retained".
    ///
    /// The count is deliberately large. Arena capacity moves in chunks, and a
    /// freshly parsed document has enough spare capacity in its last chunk to
    /// absorb a few hundred queries without asking the backing allocator for
    /// anything -- which would read as "no leak" when there very much is one.
    fn runLeakGate(self: *Runner) !void {
        const name = "leak/find_repeat";
        if (!self.wanted(name)) return;

        const query_count = 2000;
        var shape = corpus.presetByName("dense").?;
        shape.target_bytes = self.scale(shape.target_bytes);
        const html = try corpus.generate(self.gpa, shape);
        defer self.gpa.free(html);

        self.counting.reset();
        var doc = try zq.Document.initFromSlice(self.measured, html);
        defer doc.deinit();

        var q = doc.query(self.measured);
        defer q.deinit();

        const after_parse = doc.arena.queryCapacity();

        const started = Io.Clock.now(.awake, self.io);
        var i: u32 = 0;
        var sink: usize = 0;
        while (i < query_count) : (i += 1) {
            const sel = try q.find("div.row a.link");
            sink += sel.len();
        }
        std.mem.doNotOptimizeAway(&sink);
        const elapsed: u64 = @intCast(started.untilNow(self.io, .awake).toNanoseconds());

        const after_finds = doc.arena.queryCapacity();
        const retained = after_finds -| after_parse;
        try self.add(.{
            .name = name,
            .iters = query_count,
            .batches = 1,
            .ns_min = elapsed / query_count,
            .ns_p50 = elapsed / query_count,
            .ns_p99 = elapsed / query_count,
            .peak_bytes = self.counting.peak,
            .growth_per_op = retained / query_count,
            .alloc_count_per_op = self.counting.alloc_count / query_count,
            .doc_grew = retained > 0,
        });

        std.debug.print(
            "   ^ document arena: {d} KB after parse -> {d} KB after {d} finds ({d}x)\n",
            .{
                after_parse / 1024,
                after_finds / 1024,
                query_count,
                if (after_parse == 0) 0 else after_finds / after_parse,
            },
        );
    }

    fn runDocumentSuite(self: *Runner) !void {
        var shape = corpus.presetByName("medium").?;
        shape.target_bytes = self.scale(shape.target_bytes);
        const html = try corpus.generate(self.gpa, shape);
        defer self.gpa.free(html);

        if (self.wanted("render/document")) {
            var doc = try zq.Document.initFromSlice(self.measured, html);
            defer doc.deinit();
            var ctx: RenderCtx = .{ .alloc = self.measured, .doc = &doc };
            var stats = try harness.measure("render/document", self.io, self.counting, .{}, &ctx, RenderCtx.step);
            stats.bytes_in = html.len;
            try self.add(stats);
        }

        if (self.wanted("clone/document")) {
            var doc = try zq.Document.initFromSlice(self.measured, html);
            defer doc.deinit();
            var ctx: CloneCtx = .{ .alloc = self.measured, .doc = &doc };
            var stats = try harness.measure("clone/document", self.io, self.counting, .{}, &ctx, CloneCtx.step);
            stats.bytes_in = html.len;
            try self.add(stats);
        }

        if (self.wanted("text/document")) {
            var doc = try zq.Document.initFromSlice(self.measured, html);
            defer doc.deinit();
            var q = doc.query(self.measured);
            defer q.deinit();
            var ctx: TextCtx = .{ .q = &q };
            const stats = try self.measureOnDocument("text/document", &doc, &q, .{
                .max_growth_bytes = 256 << 20,
            }, &ctx, TextCtx.step);
            try self.add(stats);
        }

        const traversals = [_]struct { name: []const u8, kind: TraverseCtx.Kind }{
            .{ .name = "traverse/children", .kind = .children },
            .{ .name = "traverse/parent", .kind = .parent },
            .{ .name = "traverse/siblings", .kind = .siblings },
            .{ .name = "traverse/next_all", .kind = .next_all },
            .{ .name = "traverse/filter", .kind = .filter },
            .{ .name = "traverse/first", .kind = .first },
        };

        for (traversals) |t| {
            if (!self.wanted(t.name)) continue;
            var doc = try zq.Document.initFromSlice(self.measured, html);
            defer doc.deinit();
            var q = doc.query(self.measured);
            defer q.deinit();
            const base = try q.find("div");
            var ctx: TraverseCtx = .{ .q = &q, .base = base, .kind = t.kind };
            const stats = try self.measureOnDocument(t.name, &doc, &q, .{
                .max_growth_bytes = 256 << 20,
            }, &ctx, TraverseCtx.step);
            try self.add(stats);
        }
    }

    /// Deeply nested input. Every one of these exercises a traversal that
    /// currently recurses once per DOM level.
    fn runDeepSuite(self: *Runner) !void {
        const depths = [_]u32{ 1_000, 10_000, 50_000 };
        for (depths) |depth| {
            const html = try corpus.generateNested(self.gpa, depth);
            defer self.gpa.free(html);

            const parse_name = try self.own("deep/parse_{d}", .{depth});
            if (self.wanted(parse_name)) {
                var ctx: ParseCtx = .{ .alloc = self.measured, .html = html };
                var stats = try harness.measure(parse_name, self.io, self.counting, .{
                    .max_batches = 5,
                    .min_batches = 1,
                    .warmup_iters = 0,
                    .min_total_ns = 50 * std.time.ns_per_ms,
                }, &ctx, ParseCtx.step);
                stats.bytes_in = html.len;
                try self.add(stats);
            }

            const render_name = try self.own("deep/render_{d}", .{depth});
            if (self.wanted(render_name)) {
                var doc = try zq.Document.initFromSlice(self.measured, html);
                defer doc.deinit();
                var ctx: RenderCtx = .{ .alloc = self.measured, .doc = &doc };
                var stats = try harness.measure(render_name, self.io, self.counting, .{
                    .max_batches = 5,
                    .min_batches = 1,
                    .warmup_iters = 0,
                    .min_total_ns = 50 * std.time.ns_per_ms,
                }, &ctx, RenderCtx.step);
                stats.bytes_in = html.len;
                try self.add(stats);
            }

            const find_name = try self.own("deep/find_{d}", .{depth});
            if (self.wanted(find_name)) {
                var doc = try zq.Document.initFromSlice(self.measured, html);
                defer doc.deinit();
                var q = doc.query(self.measured);
                defer q.deinit();
                var ctx: FindCtx = .{ .q = &q, .selector = "a.link" };
                const stats = try harness.measure(find_name, self.io, self.counting, .{
                    .max_batches = 5,
                    .min_batches = 1,
                    .warmup_iters = 0,
                    .min_total_ns = 50 * std.time.ns_per_ms,
                    .max_growth_bytes = 128 << 20,
                }, &ctx, FindCtx.step);
                try self.add(stats);
            }
        }

        const wide_html = try corpus.generateWide(self.gpa, 100_000);
        defer self.gpa.free(wide_html);

        if (self.wanted("deep/wide_nth_child")) {
            var doc = try zq.Document.initFromSlice(self.measured, wide_html);
            defer doc.deinit();
            var q = doc.query(self.measured);
            defer q.deinit();
            var ctx: FindCtx = .{ .q = &q, .selector = "span:nth-child(2n+1)" };
            const stats = try harness.measure("deep/wide_nth_child", self.io, self.counting, .{
                .max_batches = 5,
                .min_batches = 1,
                .warmup_iters = 0,
                .min_total_ns = 50 * std.time.ns_per_ms,
                .max_growth_bytes = 128 << 20,
            }, &ctx, FindCtx.step);
            try self.add(stats);
        }
    }

    fn runCorpusDir(self: *Runner, dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| {
            std.debug.print("corpus: cannot open {s}: {s}\n", .{ dir_path, @errorName(err) });
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".html")) continue;

            const html = try dir.readFileAlloc(self.io, entry.name, self.gpa, .limited(64 << 20));
            defer self.gpa.free(html);

            const parse_name = try self.own("corpus/parse:{s}", .{entry.name});
            if (self.wanted(parse_name)) {
                var ctx: ParseCtx = .{ .alloc = self.measured, .html = html };
                var stats = try harness.measure(parse_name, self.io, self.counting, .{}, &ctx, ParseCtx.step);
                stats.bytes_in = html.len;
                try self.add(stats);
            }

            const find_name = try self.own("corpus/find:{s}", .{entry.name});
            if (self.wanted(find_name)) {
                var doc = try zq.Document.initFromSlice(self.measured, html);
                defer doc.deinit();
                var q = doc.query(self.measured);
                defer q.deinit();
                var ctx: FindCtx = .{ .q = &q, .selector = "div a" };
                const stats = try harness.measure(find_name, self.io, self.counting, .{
                    .max_growth_bytes = 128 << 20,
                }, &ctx, FindCtx.step);
                try self.add(stats);
            }
        }
    }

    /// Run the same workload at 1x, 2x and 4x input and fit an exponent.
    ///
    /// A linear algorithm scores ~1.0 and a quadratic one ~2.0. This is the
    /// check that survives a noisy machine: absolute timings drift, but the
    /// ratio between three runs on the same machine does not.
    fn runScaling(self: *Runner) !void {
        std.debug.print("\n scaling (exponent: 1.0 = linear, 2.0 = quadratic)\n", .{});
        std.debug.print(" ----------------------------------------- -------- ----------------------------\n", .{});

        const base: usize = if (self.config.quick) 60_000 else 400_000;
        const sizes = [3]usize{ base, base * 2, base * 4 };

        var htmls: [3][]u8 = undefined;
        for (sizes, 0..) |size, i| {
            var shape = corpus.presetByName("medium").?;
            shape.target_bytes = size;
            htmls[i] = try corpus.generate(self.gpa, shape);
        }
        defer for (htmls) |h| self.gpa.free(h);

        // Parsing first, then each selector.
        {
            var ns: [3]u64 = undefined;
            for (htmls, 0..) |html, i| {
                var ctx: ParseCtx = .{ .alloc = self.measured, .html = html };
                const s = try harness.measure("scale", self.io, self.counting, .{
                    .min_total_ns = 150 * std.time.ns_per_ms,
                    .max_batches = 60,
                }, &ctx, ParseCtx.step);
                ns[i] = s.ns_p50;
            }
            try self.addScaling("parse", ns);
        }

        for (selectors) |entry| {
            if (!self.wanted(entry.name)) continue;
            var ns: [3]u64 = undefined;
            for (htmls, 0..) |html, i| {
                var doc = try zq.Document.initFromSlice(self.measured, html);
                defer doc.deinit();
                var q = doc.query(self.measured);
                defer q.deinit();
                var ctx: FindCtx = .{ .q = &q, .selector = entry.sel };
                const s = try harness.measure("scale", self.io, self.counting, .{
                    .min_total_ns = 150 * std.time.ns_per_ms,
                    .max_batches = 60,
                    .max_growth_bytes = 128 << 20,
                }, &ctx, FindCtx.step);
                ns[i] = s.ns_p50;
            }
            try self.addScaling(entry.name, ns);
        }
    }

    /// Above this, a workload is doing more than linear work.
    ///
    /// A genuinely linear selector does not measure 1.00 here: quadrupling the
    /// document takes it out of one cache level and into the next, and the
    /// per-call bookkeeping grows with the result set. On the machine this was
    /// developed on, linear selectors land between 1.20 and 1.50 and vary by
    /// about 0.1 between runs, while the quadratic ones scored 1.78 (`:nth-child`
    /// rescanning siblings) through 2.16 (`:has()` rescanning the document).
    /// 1.60 sits in the gap, with room for run-to-run noise on either side.
    const superlinear_threshold = 1.60;

    fn addScaling(self: *Runner, name: []const u8, ns: [3]u64) !void {
        // Average the two doublings: log2(t2/t1) and log2(t4/t2).
        const exponent = if (ns[0] == 0 or ns[1] == 0)
            0.0
        else
            (std.math.log2(@as(f64, @floatFromInt(ns[2])) / @as(f64, @floatFromInt(ns[0])))) / 2.0;

        const owned = try self.own("{s}", .{name});
        try self.scaling_rows.append(self.gpa, .{ .name = owned, .exponent = exponent, .ns = ns });

        if (exponent > superlinear_threshold) self.violations += 1;
        const flag: []const u8 = if (exponent > superlinear_threshold) "  <== superlinear" else "";
        std.debug.print(" {s: <41} {d:8.2}   {d}/{d}/{d} ns{s}\n", .{
            name, exponent, ns[0], ns[1], ns[2], flag,
        });
    }

    fn report(self: *Runner) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);

        if (self.config.json_path) |path| {
            try harness.writeJson(self.gpa, &out, self.results.items);
            const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, out.items);
            std.debug.print("\nwrote {s} ({d} benchmarks)\n", .{ path, self.results.items.len });
        }

        var doc_growers: u32 = 0;
        for (self.results.items) |s| {
            if (s.doc_grew) {
                doc_growers += 1;
                self.violations += 1;
            }
        }
        std.debug.print("\n{d} benchmarks; {d} grew the document arena (must be 0)\n", .{
            self.results.items.len, doc_growers,
        });
        std.debug.print("B/op is query-arena bytes per operation, reclaimed by Query.deinit/reset\n", .{});
    }
};
