# lmdb
[Lmdb](https://github.com/LMDB/lmdb/tree/mdb.master/libraries/liblmdb) using the [Zig](https://ziglang.org/) build system

## Usage

First, update your `build.zig.zon`:

```elvish
# Initialize a `zig build` project if you haven't already
zig init
# Support for `lmdb` starts with v0.9.31 and future releases
zig fetch --save https://github.com/allyourcodebase/lmdb/archive/refs/tags/0.9.31+2.tar.gz
# For latest git commit
zig fetch --save https://github.com/allyourcodebase/lmdb/archive/refs/heads/main.tar.gz
```

Import `lmdb` dependency into `build.zig` as follows:

```zig
    const lmdb_dep = b.dependency("lmdb", .{
        .target = target,
        .optimize = optimize,
        .strip = true,
        .lto = true,
        .linkage = .static,
    });
```

Using `lmdb` artifacts and module in your project
```zig
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe.want_lto = lto;

    const liblmdb = lmdb_dep.artifact("lmdb");
    const lmdb_module = lmdb_dep.module("lmdb");

    exe.root_module.addImport("mdb", lmdb_module);
    exe.linkLibrary(liblmdb);
```

## Supported on Linux, macOS and Windows
- Zig 0.15.0-dev
- Zig 0.14.1
