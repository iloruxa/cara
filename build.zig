const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const host = b.addExecutable(.{
        .name = "marauder-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(host);

    const renderer = b.addExecutable(.{
        .name = "marauder-renderer",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/renderer/main.zig"), .target = target, .optimize = optimize }),
    });

    b.installArtifact(renderer);

    // `zig build run` runs the host, which will eventually spawn the renderer.
    const run_host = b.addRunArtifact(host);
    const run_step = b.step("run", "Run the host process");
    run_step.dependOn(&run_host.step);
}
