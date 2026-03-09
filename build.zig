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
    };

    // Run inline tests from the library module itself.
    const lib_tests = b.addTest(.{
        .root_module = zigquery_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

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
