# lmdb
[Lmdb](https://github.com/LMDB/lmdb/tree/mdb.master/libraries/liblmdb) using the [Zig](https://ziglang.org/) build system

## Usage

First, update your `build.zig.zon`:

```elvish
# Initialize a `zig build` project if you haven't already
zig init
# Support for `lmdb` starts with 0.9.31 and future releases
zig fetch --save https://github.com/Ultra-Code/lmdb/archive/refs/tags/0.9.31.tar.gz
```

Import `lmdb` dependency into build `build.zig` as follows:

```zig
    const lmdb_dep = b.dependency("lmdb", .{
        .target = target,
        .optimize = optimize,
        .lto = true,
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
- Zig 0.14.0-dev
- Zig 0.13.0
