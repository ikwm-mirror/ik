const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const neuswc_dep = b.dependency("neuswc", .{
        .target = target,
        .optimize = optimize,
        .linkage = std.builtin.LinkMode.static,
        .xwayland = false,
    });

    const swc_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/swc_include.h"),
        .target = target,
        .optimize = optimize,
    });
    swc_tc.addIncludePath(.{ .cwd_relative = "/usr/include" });
    swc_tc.addIncludePath(.{ .cwd_relative = "/usr/include/libdrm" });
    swc_tc.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    swc_tc.addIncludePath(neuswc_dep.path("libswc"));

    const swc_mod = swc_tc.createModule();

    const dynlib: std.Build.Module.LinkSystemLibraryOptions = .{ .preferred_link_mode = .dynamic };

    const ikwm_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ikwm_mod.addImport("swc", swc_mod);
    ikwm_mod.linkLibrary(neuswc_dep.artifact("swc"));
    ikwm_mod.linkSystemLibrary("wayland-server", dynlib);
    ikwm_mod.linkSystemLibrary("wayland-client", dynlib);
    ikwm_mod.linkSystemLibrary("xkbcommon", dynlib);
    ikwm_mod.linkSystemLibrary("drm", dynlib);
    ikwm_mod.linkSystemLibrary("pixman-1", dynlib);
    ikwm_mod.linkSystemLibrary("input", dynlib);
    ikwm_mod.linkSystemLibrary("libudev", dynlib);
    ikwm_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "ikwm",
        .root_module = ikwm_mod,
        .use_llvm = true,
        .use_lld = true,
    });

    b.installArtifact(exe);

    const ctl_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    ctl_mod.addCSourceFile(.{ .file = b.path("src/ikwmc.c"), .flags = &.{"-std=c11"} });
    ctl_mod.link_libc = true;

    const ctl = b.addExecutable(.{
        .name = "ikwmc",
        .root_module = ctl_mod,
    });

    b.installArtifact(ctl);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ikwm");
    run_step.dependOn(&run_cmd.step);
}
