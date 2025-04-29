# libunwind

## Zig build of [LLVM libunwind](https://github.com/llvm/llvm-project/tree/main/libunwind).

### Usage

1. Add `libunwind` dependency to `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/allyourcodebase/libunwind.git
```

2. Use `libunwind` dependency in `build.zig`:

```zig
const libunwind_dep = b.dependency("libunwind", .{
    .target = target,
    .optimize = optimize,
});
const libunwind_art = libunwind_dep.artifact("unwind");
<std.Build.Step.Compile>.linkLibrary(libunwind_art);
```
