const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lmdb_upstream = b.dependency(
        "lmdb",
        .{ .target = target, .optimize = optimize },
    );
    const lmdb_root = "libraries/liblmdb";

    const lib = b.addStaticLibrary(.{
        .name = "lmdb",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lmdb_src = .{
        "mdb.c",
        "mdb_copy.c",
        "mdb_drop.c", //mdb_drop is available only on master
        "mdb_dump.c",
        "mdb_load.c",
        "mdb_stat.c",
        "midl.c",
        "mplay.c",
    };
    const cflags = .{ "-pthread", "-std=c23" };

    lib.addCSourceFiles(.{
        .root = lmdb_upstream.path(lmdb_root),
        .files = &lmdb_src,
        .flags = &cflags,
    });
    lib.addIncludePath(lmdb_upstream.path(lmdb_root));
    lib.root_module.addCMacro("_XOPEN_SOURCE", "600");

    const lmdb_includes = .{
        "lmdb.h",
        "midl.h",
    };

    lib.installHeadersDirectory(
        lmdb_upstream.path(lmdb_root),
        "include",
        .{ .include_extensions = &lmdb_includes },
    );

    b.installArtifact(lib);

    const lmdb_api = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("lmdb", .{
        .root_source_file = lmdb_api.getOutput(),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(lmdb_upstream.path(lmdb_root));

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lmdb_test = .{
        "mtest.c",
        "mtest2.c",
        "mtest3.c",
        "mtest4.c",
        "mtest5.c",
        "mtest6.c",
    };

    lib_unit_tests.addCSourceFiles(.{
        .root = lmdb_upstream.path(lmdb_root),
        .files = &lmdb_test,
        .flags = &cflags,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
