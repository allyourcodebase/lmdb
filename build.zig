const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

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

    // writing WritingLibFiles isn't implemented on windows
    // and zld the only linker suppored on macos
    const is_macos = builtin.os.tag == .macos;
    const is_windows = builtin.os.tag == .windows;
    const use_lld = if (is_macos) false else if (is_windows) true else switch (optimize) {
        .Debug => false,
        else => true,
    };
    const liblmdb = b.addStaticLibrary(.{
        .name = "lmdb",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .use_llvm = switch (optimize) {
            .Debug => if (is_windows) true else false,
            else => true,
        },
        .use_lld = use_lld,
    });
    liblmdb.want_lto = if (is_macos) false else lto;
    liblmdb.root_module.sanitize_c = false;

    const liblmdb_src = .{
        "mdb.c",
        "midl.c",
    };
    const lmdb_includes = .{
        "lmdb.h",
        "midl.h",
    };
    const cflags = .{
        "-pthread",
        "-std=c23",
    };

    liblmdb.addCSourceFiles(.{
        .root = lmdb_upstream.path(lmdb_root),
        .files = &liblmdb_src,
        .flags = &cflags,
    });
    liblmdb.addIncludePath(lmdb_upstream.path(lmdb_root));
    liblmdb.root_module.addCMacro("_XOPEN_SOURCE", "600");
    if (is_macos) {
        liblmdb.root_module.addCMacro("_DARWIN_C_SOURCE", "");
    }

    liblmdb.installHeadersDirectory(
        lmdb_upstream.path(lmdb_root),
        "",
        .{ .include_extensions = &lmdb_includes },
    );

    b.installArtifact(liblmdb);

    const lmdb_tools = [_][]const u8{
        "mdb_copy.c",
        "mdb_drop.c",
        "mdb_dump.c",
        "mdb_load.c",
        "mdb_stat.c",
        "mplay.c",
    };

    const tools_step = b.step("tools", "Install lmdb tools");

    for (lmdb_tools) |tool_file| {
        const bin_name = tool_file[0..mem.indexOfScalar(u8, tool_file, '.').?];
        const tool = b.addExecutable(.{
            .name = bin_name,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .use_llvm = switch (optimize) {
                .Debug => false,
                else => true,
            },
            .use_lld = use_lld,
        });
        tool.root_module.sanitize_c = false;

        tool.addCSourceFiles(.{
            .root = lmdb_upstream.path(lmdb_root),
            .files = &.{tool_file},
            .flags = &cflags,
        });
        tool.addIncludePath(lmdb_upstream.path(lmdb_root));
        tool.root_module.addCMacro("_XOPEN_SOURCE", "600");
        if (is_macos) {
            tool.root_module.addCMacro("_DARWIN_C_SOURCE", "");
        }
        tool.linkLibrary(liblmdb);

        const install_tool = b.addInstallArtifact(tool, .{});
        tools_step.dependOn(&install_tool.step);
    }

    const lmdb_api = b.addTranslateC(.{
        .root_source_file = b.path("include/c.h"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    if (@hasDecl(std.Build.Step.TranslateC, "addIncludeDir")) {
        const path = lmdb_upstream.path(lmdb_root);
        const absolute_include = path.getPath2(b, null);
        lmdb_api.addIncludeDir(absolute_include);
    } else {
        lmdb_api.addIncludePath(lmdb_upstream.path(lmdb_root));
    }

    _ = b.addModule("lmdb", .{
        .root_source_file = lmdb_api.getOutput(),
        .target = target,
        .optimize = optimize,
    });

    const cflags_test = .{
        "-pthread",
        "-std=c17", //c23 forbids function use without prototype
        "-Wno-format",
        "-Wno-implicit-function-declaration",
    };

    const lmdb_test = [_][]const u8{
        "mtest.c",
        "mtest2.c",
        "mtest3.c",
        "mtest4.c",
        "mtest5.c",
        // "mtest6.c", // disabled as it requires building liblmdb with MDB_DEBUG
    };

    const test_step = b.step("install-test", "Install lmdb unit tests");
    const test_subpath = "test/";

    for (lmdb_test) |test_file| {
        const test_name = test_file[0..mem.indexOfScalar(u8, test_file, '.').?];
        const test_exe = b.addExecutable(.{
            .name = test_name,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .use_lld = use_lld,
        });
        test_exe.root_module.sanitize_c = false;

        test_exe.addCSourceFiles(.{
            .root = lmdb_upstream.path(lmdb_root),
            .files = &.{test_file},
            .flags = &cflags_test,
        });
        test_exe.addIncludePath(lmdb_upstream.path(lmdb_root));

        test_exe.linkLibrary(liblmdb);

        const install_test_exe = b.addInstallArtifact(test_exe, .{ .dest_dir = .{ .override = .{
            .custom = test_subpath,
        } } });
        test_step.dependOn(&install_test_exe.step);
    }

    const create_testdb = struct {
        fn make(step: *std.Build.Step, options: blk: {
            if (@hasDecl(std.Build.Step, "MakeOptions")) {
                break :blk std.Build.Step.MakeOptions;
            } else {
                break :blk std.Progress.Node;
            }
        }) !void {
            _ = options;
            const step_build = step.owner;
            std.fs.cwd().makeDir(step_build.fmt(
                "{s}/{s}/testdb/",
                .{ step_build.install_prefix, test_subpath },
            )) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => unreachable,
            };
        }
    }.make;
    test_step.makeFn = create_testdb;
}
