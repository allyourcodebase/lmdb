const std = @import("std");
const mem = std.mem;
const Build = std.Build;
const Step = Build.Step;
const Compile = Step.Compile;
const builtin = @import("builtin");

const MakeOptions = if (@hasDecl(Step, "MakeOptions"))
    Step.MakeOptions
else
    std.Progress.Node;

const lmdb_root = "libraries/liblmdb";

const cflags = .{
    "-pthread",
    "-std=c23",
};

pub fn build(b: *Build) void {
    if (comptime !checkVersion())
        @compileError("Update your zig toolchain to >= 0.13.0");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const lto = b.option(bool, "lto", "Enable link time optimization") orelse false;

    const lmdb_upstream = b.dependency(
        "lmdb",
        .{ .target = target, .optimize = optimize },
    );

    const build_opt: BuildOpt = .{
        .lmdb_upstream = lmdb_upstream,
        .lto_option = lto,
        .strip_option = strip,
        .target = target,
        .optimize = optimize,
    };
    const lmdb: BuildLmdb = .{
        .b = b,
        .opt = build_opt,
    };

    const liblmdb = lmdb.lib();
    lmdb.tools(liblmdb);
    lmdb.api();
    lmdb.tests(liblmdb);
}

const BuildLmdb = struct {
    b: *Build,
    opt: BuildOpt,

    fn lib(bl: BuildLmdb) *Compile {
        const opt = bl.opt;
        const b = bl.b;
        const liblmdb = b.addStaticLibrary(.{
            .name = "lmdb",
            .target = opt.target,
            .optimize = opt.optimize,
            .link_libc = true,
            .strip = opt.strip_option,
            .use_llvm = opt.use_llvm(),
            .use_lld = opt.use_lld(),
        });
        liblmdb.want_lto = opt.use_lto();
        liblmdb.root_module.sanitize_c = false;

        const lmdb_includes = .{
            "lmdb.h",
            "midl.h",
        };
        const liblmdb_src = .{
            "mdb.c",
            "midl.c",
        };

        liblmdb.addCSourceFiles(.{
            .root = opt.lmdb_upstream.path(lmdb_root),
            .files = &liblmdb_src,
            .flags = &cflags,
        });
        liblmdb.addIncludePath(opt.lmdb_upstream.path(lmdb_root));
        liblmdb.root_module.addCMacro("_XOPEN_SOURCE", "600");
        if (opt.isMacos()) {
            liblmdb.root_module.addCMacro("_DARWIN_C_SOURCE", "");
        }

        liblmdb.installHeadersDirectory(
            opt.lmdb_upstream.path(lmdb_root),
            "",
            .{ .include_extensions = &lmdb_includes },
        );
        b.installArtifact(liblmdb);

        return liblmdb;
    }

    fn api(bl: BuildLmdb) void {
        const b = bl.b;
        const opt = bl.opt;
        const lmdb_api = b.addTranslateC(.{
            .root_source_file = b.path("include/c.h"),
            .target = b.graph.host,
            .optimize = .Debug,
        });

        if (@hasDecl(Step.TranslateC, "addIncludeDir")) {
            const path = opt.lmdb_upstream.path(lmdb_root);
            const absolute_include = path.getPath2(b, null);
            lmdb_api.addIncludeDir(absolute_include);
        } else {
            lmdb_api.addIncludePath(opt.lmdb_upstream.path(lmdb_root));
        }

        _ = b.addModule("lmdb", .{
            .root_source_file = lmdb_api.getOutput(),
            .target = opt.target,
            .optimize = opt.optimize,
        });
    }

    fn tools(bl: BuildLmdb, liblmdb: *Compile) void {
        const b = bl.b;
        const tools_step = b.step("tools", "Install lmdb tools");

        const build_tools = struct {
            fn build_tools(bl_: BuildLmdb, liblmdb_: *Compile, tools_step_: *Step, lmdb_tools: []const []const u8) void {
                const b_ = bl_.b;
                const opt_ = bl_.opt;
                for (lmdb_tools) |tool_file| {
                    const bin_name = tool_file[0..mem.indexOfScalar(u8, tool_file, '.').?];
                    const tool = b_.addExecutable(.{
                        .name = bin_name,
                        .target = opt_.target,
                        .optimize = opt_.optimize,
                        .link_libc = true,
                        .strip = opt_.strip_option,
                        .use_llvm = opt_.use_llvm(),
                        .use_lld = opt_.use_lld(),
                    });
                    tool.root_module.sanitize_c = false;

                    tool.addCSourceFiles(.{
                        .root = opt_.lmdb_upstream.path(lmdb_root),
                        .files = &.{tool_file},
                        .flags = &cflags,
                    });
                    tool.addIncludePath(opt_.lmdb_upstream.path(lmdb_root));
                    tool.root_module.addCMacro("_XOPEN_SOURCE", "600");
                    if (opt_.isMacos()) {
                        tool.root_module.addCMacro("_DARWIN_C_SOURCE", "");
                    }
                    tool.linkLibrary(liblmdb_);

                    const install_tool = b_.addInstallArtifact(tool, .{});
                    tools_step_.dependOn(&install_tool.step);
                }
            }
        }.build_tools;

        const core_tools = [_][]const u8{
            "mdb_copy.c",
            "mdb_drop.c",
            "mdb_dump.c",
            "mdb_load.c",
            "mdb_stat.c",
        };
        build_tools(bl, liblmdb, tools_step, core_tools[0..]);

        // Disable mplay because windows doesn't have the posix system header
        // 'sys/wait.h' and it doesn't compile on `musl` libc becaues `stdin`
        // and `stdout` are defined as `const` which `mplay.c` tries to modify
        const extra_tools = [_][]const u8{"mplay.c"};
        const disable_mplay = true;
        if (!disable_mplay) build_tools(bl, liblmdb, tools_step, extra_tools[0..]);
    }

    fn tests(bl: BuildLmdb, liblmdb: *Compile) void {
        const b = bl.b;
        const opt = bl.opt;
        const install_test_step = b.step("install-test", "Install lmdb tests");

        const install_test_subpath = "test/";
        install_test_step.makeFn = struct {
            fn makeFn(step: *Step, options: MakeOptions) !void {
                _ = options;
                const step_build = step.owner;
                std.fs.cwd().makeDir(step_build.fmt(
                    "{s}/{s}/testdb/",
                    .{ step_build.install_prefix, install_test_subpath },
                )) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => unreachable,
                };
            }
        }.makeFn;

        const create_testdb = struct {
            fn makeFn(step: *Step, options: MakeOptions) !void {
                _ = options;
                const test_run = Step.cast(step, Step.Run).?;
                const subpath = "testdb/";
                if (@hasDecl(Build.LazyPath, "getPath3")) {
                    const bin_path = test_run.cwd.?.getPath3(step.owner, step);
                    bin_path.makePath(subpath) catch unreachable;
                } else {
                    const bin_path = test_run.cwd.?.getPath2(step.owner, step);
                    const owner = test_run.step.owner;
                    const full_path = owner.fmt("{s}/{s}", .{ bin_path, subpath });
                    owner.cache_root.handle.makeDir(full_path) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => unreachable,
                    };
                }
            }

            fn create_testdb(owner: *Build, test_dirname: Build.LazyPath) *Step {
                const run = Step.Run.create(owner, "create testdb at the generated path");
                run.step.makeFn = makeFn;
                run.setCwd(test_dirname);

                return &run.step;
            }
        }.create_testdb;

        const test_step = b.step("test", "Run lmdb tests");

        const lmdb_test = [_][]const u8{
            "mtest.c",
            "mtest2.c",
            "mtest3.c",
            "mtest4.c",
            "mtest5.c",
            // "mtest6.c", // disabled as it requires building liblmdb with MDB_DEBUG
        };

        const cflags_test = .{
            "-pthread",
            "-std=c17", //c23 forbids function use without prototype
            "-Wno-format",
            "-Wno-implicit-function-declaration",
        };

        for (lmdb_test) |test_file| {
            const test_name = test_file[0..mem.indexOfScalar(u8, test_file, '.').?];

            const test_exe = b.addExecutable(.{
                .name = test_name,
                .target = opt.target,
                .optimize = .Debug,
                .link_libc = true,
                .use_lld = opt.use_lld(),
            });
            test_exe.root_module.sanitize_c = false;

            test_exe.addCSourceFiles(.{
                .root = opt.lmdb_upstream.path(lmdb_root),
                .files = &.{test_file},
                .flags = &cflags_test,
            });
            test_exe.addIncludePath(opt.lmdb_upstream.path(lmdb_root));
            test_exe.linkLibrary(liblmdb);

            const test_dirname = test_exe.getEmittedBin().dirname();

            const install_test_exe = b.addInstallArtifact(test_exe, .{ .dest_dir = .{ .override = .{
                .custom = install_test_subpath,
            } } });

            const run = b.addRunArtifact(test_exe);
            run.setCwd(test_dirname);
            run.expectExitCode(0);
            run.enableTestRunnerMode();

            const run_create_testdb = create_testdb(run.step.owner, test_dirname);
            run_create_testdb.dependOn(&test_exe.step);
            run.step.dependOn(run_create_testdb);
            test_step.dependOn(&run.step);

            install_test_step.dependOn(&install_test_exe.step);
        }
    }
};

const BuildOpt = struct {
    lmdb_upstream: *Build.Dependency,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip_option: bool,
    lto_option: bool,

    fn isOs(os: std.Target.Os.Tag, target: Build.ResolvedTarget) bool {
        return builtin.os.tag == os or target.result.os.tag == os;
    }

    fn isMacos(opt: BuildOpt) bool {
        return isOs(.macos, opt.target);
    }

    fn isWindows(opt: BuildOpt) bool {
        return isOs(.windows, opt.target);
    }

    fn use_lto(opt: BuildOpt) bool {
        return if (opt.isMacos()) false else if (opt.use_lld()) opt.lto_option else false;
    }

    fn use_llvm(opt: BuildOpt) bool {
        return switch (opt.optimize) {
            .Debug => if (opt.isWindows()) true else false,
            else => true,
        };
    }

    // writing WritingLibFiles in zld isn't implemented on windows
    // and zld is the only linker supported on macos
    fn use_lld(opt: BuildOpt) bool {
        return if (opt.isMacos()) false else if (opt.isWindows()) true else switch (opt.optimize) {
            .Debug => false,
            else => true,
        };
    }
};

// ensures the currently in-use zig version is at least the minimum required
fn checkVersion() bool {
    if (!@hasDecl(builtin, "zig_version")) {
        return false;
    }

    const needed_version = std.SemanticVersion{ .major = 0, .minor = 13, .patch = 0 };
    const version = builtin.zig_version;
    const order = version.order(needed_version);
    return order != .lt;
}
