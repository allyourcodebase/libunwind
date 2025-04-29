const std = @import("std");

pub fn build(b: *std.Build) !void {
    const install_step = b.getInstallStep();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_str = "20.1.3";
    const version = try std.SemanticVersion.parse(version_str);

    const libunwind_path = b.path("libunwind");
    const libunwind_src_path = libunwind_path.path(b, "src");
    const libunwind_test_path = libunwind_path.path(b, "test");
    const libunwind_include_path = libunwind_path.path(b, "include");

    // Configuration options
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Library installation link mode") orelse .static;
    const hide_symbols = b.option(bool, "hide_symbols", "Do not export any symbols from the static library") orelse switch (linkage) {
        .static => if (target.result.os.tag == .windows) true else false,
        .dynamic => false,
    };
    const enable_cet = b.option(bool, "enable_cet", "Build libunwind with CET enabled") orelse false;
    const enable_gcs = b.option(bool, "enable_gcs", "Build libunwind with GCS enabled") orelse false;
    const enable_assertions = b.option(bool, "enable_assertions", "Enable assertions independent of build mode") orelse true;
    const enable_pedantic = b.option(bool, "enable_pedantic", "Compile with pedantic enabled") orelse true;
    const enable_werror = b.option(bool, "enable_werror", "Fail and stop if a warning is triggered") orelse false;
    const enable_cross_unwinding = b.option(bool, "enable_cross_unwinding", "Enable cross-platform unwinding support") orelse false;
    const enable_arm_wmmx = b.option(bool, "enable_arm_wmmx", "Enable unwinding support for ARM WMMX registers") orelse false;
    const enable_threads = b.option(bool, "enable_threads", "Build libunwind with threading support") orelse true;
    const use_weak_pthread = b.option(bool, "use_weak_pthread", "Use weak references to refer to pthread functions") orelse false;
    const is_baremetal = b.option(bool, "is_baremetal", "Build libunwind for bare-metal targets") orelse false;
    const use_frame_header_cache = b.option(bool, "use_frame_header_cache", "Cache frame headers for unwinding (requires locking dl_iterate_phdr)") orelse false;
    const remember_heap_alloc = b.option(bool, "remember_heap_alloc", "Use heap instead of the stack for .cfi_remember_state") orelse false;
    const enable_frame_apis = b.option(bool, "enable_frame_apis", "Include libgcc-compatible frame APIs") orelse false;

    // Library
    const lib = b.addLibrary(.{
        .name = "unwind",
        .version = version,
        .root_module = b.createModule(.{
            .target = target,
            .link_libc = true,
            .optimize = optimize,
        }),
        .linkage = linkage,
    });
    lib.addIncludePath(libunwind_include_path);

    var flags = std.BoundedArray([]const u8, 64){};
    flags.appendSliceAssumeCapacity(&COMMON_FLAGS);
    if (target.result.os.tag == .windows) flags.appendAssumeCapacity("-Wno-dll-attribute-on-redeclaration");
    if (target.result.cpu.arch.isMIPS32() and target.result.abi.float() == .hard) flags.appendAssumeCapacity("-mfp64");
    if (enable_pedantic) flags.appendAssumeCapacity("-Wpedantic");
    if (enable_werror) flags.appendAssumeCapacity("-Werror");
    if (enable_cet) flags.appendSliceAssumeCapacity(&.{ "-fcf-protection=full", "-mshstk" });
    if (enable_gcs) flags.appendAssumeCapacity("-mbranch-protection=standard");
    if (hide_symbols) flags.appendSliceAssumeCapacity(&.{ "-fvisibility=hidden", "-fvisibility-global-new-delete=force-hidden" });
    flags.appendAssumeCapacity(if (enable_assertions) "-D_DEBUG" else "-DNDEBUG");
    if (!enable_cross_unwinding) flags.appendAssumeCapacity("-D_LIBUNWIND_IS_NATIVE_ONLY");
    if (enable_frame_apis) flags.appendAssumeCapacity("-D_LIBUNWIND_SUPPORT_FRAME_APIS");
    if (!enable_threads) flags.appendAssumeCapacity("-D_LIBUNWIND_HAS_NO_THREADS");
    if (use_weak_pthread) flags.appendAssumeCapacity("-DLIBUNWIND_USE_WEAK_PTHREAD=1");
    if (enable_arm_wmmx) flags.appendAssumeCapacity("-D__ARM_WMMX");
    if (is_baremetal) flags.appendAssumeCapacity("-D_LIBUNWIND_IS_BAREMETAL");
    if (use_frame_header_cache) flags.appendAssumeCapacity("-D_LIBUNWIND_USE_FRAME_HEADER_CACHE");
    if (remember_heap_alloc) flags.appendAssumeCapacity("-D_LIBUNWIND_REMEMBER_HEAP_ALLOC");

    flags.appendSliceAssumeCapacity(&C_FLAGS);
    lib.addCSourceFiles(.{ .root = libunwind_src_path, .files = &C_SOURCES, .flags = flags.constSlice() });
    for (0..C_FLAGS.len) |_| {
        _ = flags.pop();
    }

    flags.appendSliceAssumeCapacity(&CPP_FLAGS);
    lib.addCSourceFiles(.{ .root = libunwind_src_path, .files = if (target.result.os.tag == .aix)
        &(CPP_SOURCES ++ AIX_CPP_SOURCES)
    else
        &CPP_SOURCES, .flags = flags.constSlice() });

    lib.installHeadersDirectory(libunwind_include_path, "", .{ .include_extensions = if (target.result.ofmt == .macho)
        &(INCLUDE_HEADERS ++ MACHO_INCLUDE_HEADERS)
    else
        &INCLUDE_HEADERS });

    b.installArtifact(lib);

    // Test suite
    const tests_step = b.step("test", "Run test suite");

    inline for (TEST_EXE_SOURCES) |TEST_EXE_SOURCE| {
        const test_exe = b.addExecutable(.{
            .name = std.fs.path.stem(TEST_EXE_SOURCE),
            .version = version,
            .root_module = b.createModule(.{
                .target = target,
            }),
        });
        test_exe.addCSourceFile(.{ .file = libunwind_test_path.path(b, TEST_EXE_SOURCE), .flags = flags.constSlice() });
        test_exe.addIncludePath(libunwind_include_path);
        test_exe.linkLibrary(lib);

        const test_run = b.addRunArtifact(test_exe);
        tests_step.dependOn(&test_run.step);
    }

    inline for (TEST_OBJ_SOURCES) |TEST_OBJ_SOURCE| {
        const test_obj = b.addObject(.{
            .name = std.fs.path.stem(TEST_OBJ_SOURCE),
            .root_module = b.createModule(.{
                .target = target,
            }),
        });
        test_obj.addCSourceFile(.{ .file = libunwind_test_path.path(b, TEST_OBJ_SOURCE), .flags = flags.constSlice() });
        test_obj.addIncludePath(libunwind_include_path);
        test_obj.linkLibrary(lib);

        tests_step.dependOn(&test_obj.step);
    }

    install_step.dependOn(tests_step);

    // Formatting check
    const fmt_step = b.step("fmt", "Check formatting");

    const fmt = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
        },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
    install_step.dependOn(fmt_step);
}

const INCLUDE_HEADERS = .{
    "__libunwind_config.h",
    "libunwind.h",
    "unwind_arm_ehabi.h",
    "unwind_itanium.h",
    "unwind.h",
};

const MACHO_INCLUDE_HEADERS = .{
    "mach-o" ++ std.fs.path.sep_str ++ "compact_unwind_encoding.h",
};

const C_SOURCES = .{
    "Unwind-sjlj.c",
    "Unwind-wasm.c",
    "UnwindLevel1-gcc-ext.c",
    "UnwindLevel1.c",
};

const CPP_SOURCES = .{
    "libunwind.cpp",
    "Unwind-EHABI.cpp",
    "Unwind-seh.cpp",

    "UnwindRegistersRestore.S",
    "UnwindRegistersSave.S",
};

const AIX_CPP_SOURCES = .{
    "Unwind_AIXExtras.cpp",
};

const C_FLAGS = .{
    "-std=c99",
    "-fexceptions",
};

const CPP_FLAGS = .{
    "-std=c++17",

    "-fno-rtti",
    "-fno-exceptions",
};

const COMMON_FLAGS = .{
    "-Werror=return-type",
    "-Werror=unknown-pragmas",

    "-funwind-tables",
    "--unwindlib=none",
    "-fstrict-aliasing",

    "-fno-sanitize=all",
    "-fsanitize-coverage=0",
};

const TEST_EXE_SOURCES = .{
    "aix_runtime_link.pass.cpp",
    "bad_unwind_info.pass.cpp",
    "floatregister.pass.cpp",
    "forceunwind.pass.cpp",
    "frameheadercache_test.pass.cpp",
    "libunwind_01.pass.cpp",
    "libunwind_02.pass.cpp",
    "signal_frame.pass.cpp",
    "signal_unwind.pass.cpp",
    "unw_getcontext.pass.cpp",
    "unw_resume.pass.cpp",
    "unwind_leaffunction.pass.cpp",
    "unwind_scalable_vectors.pass.cpp",

    "aix_signal_unwind.pass.sh.S",
    "remember_state_leak.pass.sh.s",
};

const TEST_OBJ_SOURCES = .{
    "alignment.compile.pass.cpp",
};
