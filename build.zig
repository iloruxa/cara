const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glfw = try buildGlfw(b, target, optimize);

    const host = b.addExecutable(.{
        .name = "Cara",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    host.root_module.linkLibrary(glfw);
    host.root_module.addIncludePath(b.path("vendor/glfw/include"));
    host.root_module.link_libc = true;

    const glfw_module = b.createModule(.{ .root_source_file = b.path("vendor/glfw.zig"), .target = target, .optimize = optimize, .link_libc = true });

    host.root_module.addImport("glfw", glfw_module);

    b.installArtifact(host);

    const renderer = b.addExecutable(.{
        .name = "cara-renderer",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/renderer/main.zig"), .target = target, .optimize = optimize }),
    });
    renderer.root_module.link_libc = true;
    b.installArtifact(renderer);

    // --- Freetype (hexops package): Freetype's C source compiled to a `freetype`
    // static lib + its headers. The renderer owns rasterization, so only it links it
    const freetype_dep = b.dependency("freetype", .{ .target = target, .optimize = optimize });
    renderer.root_module.linkLibrary(freetype_dep.artifact("freetype"));

    // --- Luau (vendored, interpreter-only)
    // VM + Compiler + Ast built with zig c++
    // CodeGen never compiled in
    // Reached only through the C shim
    const luau = buildLuau(b, target, optimize);
    renderer.root_module.linkLibrary(luau);
    // resolve the shim's C++ symbols at final link
    renderer.root_module.link_libcpp = true;

    // Bindings: translate-c Freetype's public header at build time against the
    // package's include dir, exposed to the renderer as `freetype`
    const ft_c = b.addTranslateC(.{ .root_source_file = b.path("vendor/freetype_c.h"), .target = target, .optimize = optimize });
    ft_c.addIncludePath(freetype_dep.path("include"));
    renderer.root_module.addImport("freetype", ft_c.createModule());

    // --- IPC ---
    //
    // Frame-slot transport (the latest-wins shared region),
    // imported by both processes so the host and renderer
    // \agree on the region layout from one source of truth.
    const frame_module = b.createModule(.{
        .root_source_file = b.path("src/ipc/frame.zig"),
        .target = target,
        .optimize = optimize,
    });
    host.root_module.addImport("frame", frame_module);
    renderer.root_module.addImport("frame", frame_module);

    // IPC: Frame transport tests
    const frame_tests = b.addTest(.{ .root_module = frame_module });
    const run_frame_tests = b.addRunArtifact(frame_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_frame_tests.step);

    // IPC: Draw Module
    const draw_module = b.createModule(.{
        .root_source_file = b.path("src/ipc/draw_command.zig"),
        .target = target,
        .optimize = optimize,
    });
    host.root_module.addImport("draw", draw_module);
    renderer.root_module.addImport("draw", draw_module);

    // IPC: Draw module tests
    const draw_tests = b.addTest(.{ .root_module = draw_module });
    const run_draw_tests = b.addRunArtifact(draw_tests);
    test_step.dependOn(&run_draw_tests.step);

    // IPC: Control-channel protocol
    const protocol_module = b.createModule(.{ .root_source_file = b.path("src/ipc/protocol.zig"), .target = target, .optimize = optimize });
    host.root_module.addImport("protocol", protocol_module);
    renderer.root_module.addImport("protocol", protocol_module);

    // IPC: Control-channel protocol tests
    const protocol_tests = b.addTest(.{ .root_module = protocol_module });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    test_step.dependOn(&run_protocol_tests.step);

    // IPC: staging region (the atlas stream), imported by both processes
    const staging_module = b.createModule(.{ .root_source_file = b.path("src/ipc/staging.zig"), .target = target, .optimize = optimize });
    host.root_module.addImport("staging", staging_module);
    renderer.root_module.addImport("staging", staging_module);

    const staging_tests = b.addTest(.{ .root_module = staging_module });
    test_step.dependOn(&b.addRunArtifact(staging_tests).step);

    // --- GPU: wgpu-native (WebGPU), prebuilt static lib + translate-c bindings ---
    const wgpu_dep = b.dependency("wgpu", .{});
    const wgpu_module = b.createModule(.{
        .root_source_file = b.path("vendor/wgpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    host.root_module.addImport("wgpu", wgpu_module);

    // Link the prebuilt archive + the frameworks its Metal backed needs.
    // (IOKit + CoreFoundation already come in via glfw)
    host.root_module.addObjectFile(wgpu_dep.path("lib/libwgpu_native.a"));
    host.root_module.linkFramework("Metal", .{});
    host.root_module.linkFramework("QuartzCore", .{});
    host.root_module.linkFramework("Foundation", .{});
    host.root_module.linkFramework("IOSurface", .{});

    // --- RUN STEP ---
    //
    // `zig build run` runs the host, which will eventually spawn the renderer.
    const run_host = b.addSystemCommand(&.{"./zig-out/bin/Cara"});
    run_host.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the host process");
    run_step.dependOn(&run_host.step);
}

fn buildGlfw(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !*std.Build.Step.Compile {
    const glfw_dep = b.dependency("glfw", .{});
    const lib = b.addLibrary(.{
        .name = "glfw",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    lib.root_module.link_libc = true;
    lib.root_module.addIncludePath(glfw_dep.path("include"));

    lib.root_module.addCSourceFiles(.{ .root = glfw_dep.path(""), .files = &.{
        "src/context.c",
        "src/init.c",
        "src/input.c",
        "src/monitor.c",
        "src/platform.c",
        "src/vulkan.c",
        "src/window.c",
        "src/egl_context.c",
        "src/osmesa_context.c",
        "src/null_init.c",
        "src/null_monitor.c",
        "src/null_window.c",
        "src/null_joystick.c",
    }, .flags = &.{} });

    switch (target.result.os.tag) {
        // Wayland support Flaky for these atm
        // .freebsd, .netbsd, .openbsd, .dragonfly, .hurd
        .linux => {
            lib.root_module.addCMacro("_GLFW_WAYLAND", "");

            const wayland_headers = generateWaylandProtocols(b);
            lib.root_module.addIncludePath(wayland_headers);

            lib.root_module.addCSourceFiles(.{ .root = glfw_dep.path(""), .files = &.{
                "src/wl_init.c",
                "src/wl_monitor.c",
                "src/wl_window.c",
                "src/xkb_unicode.c",
                "src/posix_module.c",
                "src/posix_time.c",
                "src/posix_thread.c",
                "src/posix_poll.c",
            }, .flags = &.{} });

            lib.root_module.linkSystemLibrary("wayland-client", .{});
            lib.root_module.linkSystemLibrary("wayland-cursor", .{});
            lib.root_module.linkSystemLibrary("xkbcommon", .{});
        },
        .macos => {
            lib.root_module.addCMacro("_GLFW_COCOA", "");
            lib.root_module.addCSourceFiles(.{ .root = glfw_dep.path(""), .files = &.{
                "src/cocoa_init.m",
                "src/cocoa_monitor.m",
                "src/cocoa_window.m",
                "src/cocoa_joystick.m",
                "src/cocoa_time.c",
                "src/nsgl_context.m",
                "src/posix_module.c",
                "src/posix_thread.c",
            }, .flags = &.{} });
            lib.root_module.linkFramework("Cocoa", .{});
            lib.root_module.linkFramework("IOKit", .{});
            lib.root_module.linkFramework("CoreFoundation", .{});
        },
        else => {
            std.log.err(
                "Cara supports Linux (Wayland), macOS (Cocoa).\n" ++
                    "Your target '{s}' is not currently supported.\n",
                .{@tagName(target.result.os.tag)},
            );
            // @panic("Unsupported Host Operating System");
            return error.UnsupportedPlatform;
        },
    }

    return lib;
}

const luau_src = [_][]const u8{
    // Common (support code everything links: asserts, string utils, timing)
    "Common/src/BytecodeWire.cpp",
    "Common/src/StringUtils.cpp",
    "Common/src/TimeTrace.cpp",
    // Bytecode (the Compiler emits through this)
    "Bytecode/src/BytecodeBuilder.cpp",
    "Bytecode/src/BytecodeGraph.cpp",
    // VM
    "VM/src/lapi.cpp",
    "VM/src/laux.cpp",
    "VM/src/lbaselib.cpp",
    "VM/src/lbitlib.cpp",
    "VM/src/lbuffer.cpp",
    "VM/src/lbuflib.cpp",
    "VM/src/lbuiltins.cpp",
    "VM/src/lclass.cpp",
    "VM/src/lclasslib.cpp",
    "VM/src/lcorolib.cpp",
    "VM/src/ldblib.cpp",
    "VM/src/ldebug.cpp",
    "VM/src/ldo.cpp",
    "VM/src/lfunc.cpp",
    "VM/src/lgc.cpp",
    "VM/src/lgcdebug.cpp",
    "VM/src/linit.cpp",
    "VM/src/lintlib.cpp",
    "VM/src/lmathlib.cpp",
    "VM/src/lmem.cpp",
    "VM/src/lnumprint.cpp",
    "VM/src/lobject.cpp",
    "VM/src/loslib.cpp",
    "VM/src/lperf.cpp",
    "VM/src/lstate.cpp",
    "VM/src/lstring.cpp",
    "VM/src/lstrlib.cpp",
    "VM/src/ltable.cpp",
    "VM/src/ltablib.cpp",
    "VM/src/ltm.cpp",
    "VM/src/ludata.cpp",
    "VM/src/lutf8lib.cpp",
    "VM/src/lveclib.cpp",
    "VM/src/lvmexecute.cpp",
    "VM/src/lvmload.cpp",
    "VM/src/lvmutils.cpp",
    // Compiler
    "Compiler/src/BuiltinFolding.cpp",
    "Compiler/src/Builtins.cpp",
    "Compiler/src/Compiler.cpp",
    "Compiler/src/ConstantFolding.cpp",
    "Compiler/src/CostModel.cpp",
    "Compiler/src/lcode.cpp",
    "Compiler/src/TableShape.cpp",
    "Compiler/src/Types.cpp",
    "Compiler/src/ValueTracking.cpp",
    // Ast
    "Ast/src/Allocator.cpp",
    "Ast/src/Ast.cpp",
    "Ast/src/Confusables.cpp",
    "Ast/src/Cst.cpp",
    "Ast/src/Lexer.cpp",
    "Ast/src/Location.cpp",
    "Ast/src/Parser.cpp",
    "Ast/src/PrettyPrinter.cpp",
};

fn buildLuau(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const luau_dep = b.dependency("luau", .{});
    const lib = b.addLibrary(.{
        .name = "luau",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    lib.root_module.link_libc = true;
    lib.root_module.link_libcpp = true;

    const includes = [_][]const u8{
        "Common/include",
        "Ast/include",
        "Bytecode/include",
        "Compiler/include",
        "VM/include",
    };

    for (includes) |p| lib.root_module.addIncludePath(luau_dep.path(p));

    // Luau's own sources
    lib.root_module.addCSourceFiles(.{ .root = luau_dep.path(""), .files = &luau_src, .flags = &.{"-std=c++17"} });

    // Our C shim over Luau's C++ API lives in-tree
    lib.root_module.addCSourceFiles(.{ .files = &.{"vendor/luau_shim.cpp"}, .flags = &.{"-std=c++17"} });

    return lib;
}

fn generateWaylandProtocols(b: *std.Build) std.Build.LazyPath {
    const glfw_dep = b.dependency("glfw", .{});
    const headers = b.addWriteFiles();

    const protocols = [_][]const u8{ "wayland", "xdg-shell", "xdg-decoration-unstable-v1", "xdg-activation-v1", "viewporter", "relative-pointer-unstable-v1", "pointer-constraints-unstable-v1", "fractional-scale-1" };

    for (protocols) |proto| {
        const xml_path = glfw_dep.path(b.fmt("deps/wayland/{s}.xml", .{proto}));

        const header_cmd = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header_cmd.addFileArg(xml_path);

        const header_out = header_cmd.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{proto}));
        _ = headers.addCopyFile(header_out, b.fmt("{s}-client-protocol.h", .{proto}));

        const code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code_cmd.addFileArg(xml_path);

        const code_out = code_cmd.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{proto}));
        _ = headers.addCopyFile(code_out, b.fmt("{s}-client-protocol.h", .{proto}));
    }

    return headers.getDirectory();
}
