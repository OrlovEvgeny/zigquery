const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigquery_mod = b.addModule("zigquery", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zigquery",
        .root_module = zigquery_mod,
    });
    b.installArtifact(lib);

    // Benchmarks are always built in ReleaseFast: a Debug-mode timing is not
    // a measurement, and `tree.appendChild`'s cycle assertion alone makes
    // parsing O(N*depth) in safe builds.
    const bench_step = b.step("bench", "Run benchmarks (ReleaseFast)");
    const bench_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_exe = b.addExecutable(.{
        .name = "zigquery-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zigquery", .module = bench_lib_mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.stdio = .inherit;
    if (b.args) |args| run_bench.addArgs(args);
    bench_step.dependOn(&run_bench.step);

    const test_step = b.step("test", "Run unit tests");

    const test_files = [_][]const u8{
        "test/html_parser_test.zig",
        "test/css_parser_test.zig",
        "test/document_test.zig",
        "test/selection_test.zig",
        "test/traversal_test.zig",
        "test/filter_test.zig",
        "test/property_test.zig",
        "test/manipulation_test.zig",
        "test/compiled_selector_test.zig",
        "test/api_test.zig",
        "test/deep_nesting_test.zig",
        "test/pseudo_class_test.zig",
        "test/query_test.zig",
    };

    const bench_test_files = [_][]const u8{
        "bench/counting_allocator.zig",
        "bench/corpus.zig",
        "bench/harness.zig",
    };

    // Run inline tests from the library module itself.
    const lib_tests = b.addTest(.{
        .root_module = zigquery_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    for (bench_test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    for (test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigquery", .module = zigquery_mod },
                },
            }),
        });
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }
}
