const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lmdb_upstream = b.dependency(
        "lmdb",
        .{ .target = target, .optimize = optimize },
    );
    const lmdb_root = "libraries/liblmdb";

    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const lto = b.option(bool, "lto", "Enable link time optimization") orelse false;

    const lib = b.addStaticLibrary(.{
        .name = "lmdb",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .use_llvm = switch (optimize) {
            .Debug => false,
            else => true,
        },
        .use_lld = switch (optimize) {
            .Debug => false,
            else => true,
        },
    });
    lib.want_lto = lto;

    const lmdb_src = .{
        "mdb.c",
        "midl.c",
    };

    const cflags = .{
        "-pthread",
        "-std=c23",
    };

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
    const absolute_include = b.pathJoin(&.{
        lmdb_upstream.path(lmdb_root).getPath3(b, null).root_dir.path.?,
        lmdb_upstream.path(lmdb_root).getPath3(b, null).sub_path,
    });
    // TODO: update when https://github.com/ziglang/zig/pull/20851 is available
    lmdb_api.addIncludeDir(absolute_include);

    _ = b.addModule("lmdb", .{
        .root_source_file = lmdb_api.getOutput(),
        .target = target,
        .optimize = optimize,
    });

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
        .flags = &(cflags ++ .{"-Wno-format"}),
    });
    lib_unit_tests.addIncludePath(lmdb_upstream.path(lmdb_root));
    lib_unit_tests.linkLibrary(lib);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
