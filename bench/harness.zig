//! Measurement core: batched timing, percentile reporting, and per-operation
//! memory accounting.
//!
//! Operations here range from ~100 ns (`Selection.first`) to ~100 ms (parsing
//! 10 MB). A single timing strategy cannot cover that, so the runner first
//! calibrates a batch size that makes one batch last at least
//! `Options.min_batch_ns`, then times whole batches. That keeps clock overhead
//! off the fast benchmarks without inflating iteration counts on the slow ones.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;

pub const Options = struct {
    /// Keep growing the batch until one batch takes at least this long, so
    /// clock resolution and vtable overhead stay in the noise.
    min_batch_ns: u64 = 1 * std.time.ns_per_ms,
    /// Stop once the measured phase has run this long...
    min_total_ns: u64 = 200 * std.time.ns_per_ms,
    /// ...and stop unconditionally at this point, even if `min_batches` has
    /// not been reached. Some operations under test take seconds per call;
    /// without this the suite would take hours.
    max_total_ns: u64 = 4 * std.time.ns_per_s,
    /// ...or this many batches, whichever comes first.
    max_batches: u32 = 200,
    min_batches: u32 = 5,
    warmup_iters: u32 = 2,
    /// Upper bound on batch size, so a benchmark that turns out to be
    /// unexpectedly cheap cannot run for minutes.
    max_batch: u64 = 1 << 16,
    /// Hard cap on total operations, including calibration.
    max_iters: u64 = 1 << 22,
    /// Stop sampling once the workload has retained this many bytes.
    ///
    /// Several operations under test leak into the document arena by design of
    /// the current code -- that is what `Stats.growth_per_op` reports. Without
    /// a budget those benchmarks would run the machine out of memory before
    /// the time budget expired.
    max_growth_bytes: usize = 512 << 20,
};

pub const Stats = struct {
    name: []const u8,
    iters: u64,
    batches: u32,
    /// Per-operation nanoseconds.
    ns_min: u64,
    ns_p50: u64,
    ns_p99: u64,
    /// Input size for throughput reporting. Zero means "not a throughput
    /// benchmark" and suppresses the MB/s column.
    bytes_in: u64 = 0,
    /// High-water mark of live bytes during the measured phase.
    peak_bytes: usize = 0,
    /// Live bytes still checked out per operation once the operation claims to
    /// be finished. Anything above zero is a leak.
    growth_per_op: usize = 0,
    alloc_count_per_op: u64 = 0,
    /// Set when `Options.max_growth_bytes` ended sampling early, i.e. the
    /// operation retains memory fast enough to matter.
    growth_capped: bool = false,
    /// Set when a read-only query grew the *document* arena, which it never
    /// should: query results belong to the query.
    doc_grew: bool = false,

    pub fn mbPerSec(self: Stats) f64 {
        if (self.bytes_in == 0 or self.ns_p50 == 0) return 0;
        const bytes_per_ns = @as(f64, @floatFromInt(self.bytes_in)) /
            @as(f64, @floatFromInt(self.ns_p50));
        return bytes_per_ns * 1000.0; // bytes/ns -> MB/s (1e9 ns/s / 1e6 B/MB)
    }
};

/// Run `step` against `ctx` until the sampling budget is exhausted.
///
/// `ctx` must be a pointer; `step` receives it unchanged. Whatever `step`
/// produces must be fed to `std.mem.doNotOptimizeAway` by the caller, since the
/// harness cannot see the value.
pub fn measure(
    name: []const u8,
    io: Io,
    counting: *CountingAllocator,
    opts: Options,
    ctx: anytype,
    comptime step: fn (@TypeOf(ctx)) anyerror!void,
) !Stats {
    var warm: u32 = 0;
    while (warm < opts.warmup_iters) : (warm += 1) try step(ctx);

    const batch = try calibrate(io, counting, opts, ctx, step);

    var samples: [256]u64 = undefined;
    var sample_count: u32 = 0;

    counting.reset();
    const live_before = counting.live;

    var total_ns: u64 = 0;
    var total_iters: u64 = 0;
    var batches: u32 = 0;
    var capped = false;

    while (batches < opts.max_batches) : (batches += 1) {
        if (batches >= opts.min_batches and total_ns >= opts.min_total_ns) break;
        if (total_ns >= opts.max_total_ns) break;
        if (total_iters >= opts.max_iters) break;
        if (counting.live -| live_before >= opts.max_growth_bytes) {
            capped = true;
            break;
        }

        const started = Io.Clock.now(.awake, io);
        var i: u64 = 0;
        while (i < batch) : (i += 1) try step(ctx);
        const elapsed: u64 = @intCast(started.untilNow(io, .awake).toNanoseconds());

        total_ns += elapsed;
        total_iters += batch;
        if (sample_count < samples.len) {
            samples[sample_count] = elapsed / batch;
            sample_count += 1;
        }
    }

    const live_after = counting.live;

    std.mem.sort(u64, samples[0..sample_count], {}, std.sort.asc(u64));

    return .{
        .name = name,
        .iters = total_iters,
        .batches = batches,
        .ns_min = samples[0],
        .ns_p50 = percentile(samples[0..sample_count], 50),
        .ns_p99 = percentile(samples[0..sample_count], 99),
        .peak_bytes = counting.peak,
        .growth_per_op = if (live_after > live_before)
            (live_after - live_before) / total_iters
        else
            0,
        .alloc_count_per_op = counting.alloc_count / total_iters,
        .growth_capped = capped,
    };
}

/// Pick the smallest batch size whose runtime clears `min_batch_ns`.
fn calibrate(
    io: Io,
    counting: *CountingAllocator,
    opts: Options,
    ctx: anytype,
    comptime step: fn (@TypeOf(ctx)) anyerror!void,
) !u64 {
    const live_at_start = counting.live;
    var batch: u64 = 1;
    while (batch < opts.max_batch) {
        // Calibration runs real operations, so it is subject to the same
        // retention budget as the measured phase.
        if (counting.live -| live_at_start >= opts.max_growth_bytes) return batch;
        const started = Io.Clock.now(.awake, io);
        var i: u64 = 0;
        while (i < batch) : (i += 1) try step(ctx);
        const elapsed: u64 = @intCast(started.untilNow(io, .awake).toNanoseconds());

        if (elapsed >= opts.min_batch_ns) return batch;
        // Scale toward the target rather than blindly doubling, so a benchmark
        // three orders of magnitude too fast converges in a couple of rounds.
        const scaled = if (elapsed == 0)
            batch * 16
        else
            batch * @max(2, opts.min_batch_ns / @max(elapsed, 1));
        batch = @min(scaled, opts.max_batch);
    }
    return batch;
}

fn percentile(sorted: []const u64, p: u32) u64 {
    if (sorted.len == 0) return 0;
    const idx = (sorted.len * p) / 100;
    return sorted[@min(idx, sorted.len - 1)];
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

pub fn writeHeader(gpa: Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa,
        \\ benchmark                                   p50        min     MB/s   mem/in    B/op  allocs
        \\ ----------------------------------------- ---------- ---------- ------- ------ -------- ------
        \\
    );
}

pub fn writeRow(gpa: Allocator, out: *std.ArrayList(u8), s: Stats) !void {
    var line: [320]u8 = undefined;

    var mbps_buf: [16]u8 = undefined;
    const mbps_str = if (s.bytes_in == 0)
        "      -"
    else
        try std.fmt.bufPrint(&mbps_buf, "{d:7.1}", .{s.mbPerSec()});

    // Peak resident bytes per input byte. This is the arena-amplification
    // number: 12.5 today on a parse benchmark.
    var ratio_buf: [16]u8 = undefined;
    const ratio_str = if (s.bytes_in == 0)
        "     -"
    else
        try std.fmt.bufPrint(&ratio_buf, "{d:6.1}", .{
            @as(f64, @floatFromInt(s.peak_bytes)) / @as(f64, @floatFromInt(s.bytes_in)),
        });

    // A trailing '!' marks a row where the operation grew the document arena,
    // which a read-only query must never do.
    var growth_buf: [24]u8 = undefined;
    const growth_str = try std.fmt.bufPrint(&growth_buf, "{d}{s}", .{
        s.growth_per_op,
        if (s.doc_grew) "!" else "",
    });

    var p50_buf: [24]u8 = undefined;
    var min_buf: [24]u8 = undefined;

    const text = try std.fmt.bufPrint(&line, " {s: <41} {s: >10} {s: >10} {s} {s} {s: >8} {d: >6}\n", .{
        s.name,
        try formatNs(&p50_buf, s.ns_p50),
        try formatNs(&min_buf, s.ns_min),
        mbps_str,
        ratio_str,
        growth_str,
        s.alloc_count_per_op,
    });
    try out.appendSlice(gpa, text);
}

/// Render a nanosecond count with a unit, so a table can mix 120 ns and 84 ms
/// without the reader counting digits. The caller owns `buf`; two calls in one
/// argument list need two buffers.
fn formatNs(buf: []u8, ns: u64) ![]const u8 {
    if (ns < 1_000) return std.fmt.bufPrint(buf, "{d}ns", .{ns});
    if (ns < 1_000_000) return std.fmt.bufPrint(buf, "{d:.2}us", .{
        @as(f64, @floatFromInt(ns)) / 1_000.0,
    });
    if (ns < 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.2}ms", .{
        @as(f64, @floatFromInt(ns)) / 1_000_000.0,
    });
    return std.fmt.bufPrint(buf, "{d:.2}s", .{
        @as(f64, @floatFromInt(ns)) / 1_000_000_000.0,
    });
}

/// Hand-rolled rather than `std.json`, whose API has moved between the two Zig
/// versions this project supports.
pub fn writeJson(gpa: Allocator, out: *std.ArrayList(u8), all: []const Stats) !void {
    try out.appendSlice(gpa, "{\n  \"benchmarks\": [\n");
    for (all, 0..) |s, i| {
        var line: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&line,
            \\    {{"name": "{s}", "ns_p50": {d}, "ns_min": {d}, "ns_p99": {d}, "bytes_in": {d}, "peak_bytes": {d}, "growth_per_op": {d}, "doc_grew": {}, "allocs_per_op": {d}, "iters": {d}}}
        , .{
            s.name,               s.ns_p50,     s.ns_min,        s.ns_p99,
            s.bytes_in,           s.peak_bytes, s.growth_per_op, s.doc_grew,
            s.alloc_count_per_op, s.iters,
        });
        try out.appendSlice(gpa, text);
        if (i + 1 < all.len) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n");
    }
    try out.appendSlice(gpa, "  ]\n}\n");
}

test "percentile picks the expected element" {
    const xs = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(u64, 6), percentile(&xs, 50));
    try std.testing.expectEqual(@as(u64, 10), percentile(&xs, 99));
    try std.testing.expectEqual(@as(u64, 1), percentile(&xs, 0));
    try std.testing.expectEqual(@as(u64, 0), percentile(&.{}, 50));
}

test "formatNs switches units" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("999ns", try formatNs(&buf, 999));
    try std.testing.expectEqualStrings("1.50us", try formatNs(&buf, 1500));
    try std.testing.expectEqualStrings("2.00ms", try formatNs(&buf, 2_000_000));
    try std.testing.expectEqualStrings("1.50s", try formatNs(&buf, 1_500_000_000));
}

test "two formatNs calls in one argument list do not alias" {
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    var line: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&line, "{s} {s}", .{
        try formatNs(&a, 1500),
        try formatNs(&b, 2_000_000),
    });
    try std.testing.expectEqualStrings("1.50us 2.00ms", out);
}

test "mbPerSec" {
    // 1 MB in 1 ms is 1000 MB/s.
    const s: Stats = .{
        .name = "x",
        .iters = 1,
        .batches = 1,
        .ns_min = 1_000_000,
        .ns_p50 = 1_000_000,
        .ns_p99 = 1_000_000,
        .bytes_in = 1_000_000,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), s.mbPerSec(), 0.001);
}
