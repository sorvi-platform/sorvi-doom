const std = @import("std");
const sorvi = @import("sorvi");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sorvi_dep = b.dependency("sorvi", .{
        .target = target,
        .optimize = optimize,
    });
    const frontend = sorvi_dep.artifact("sorvi-frontend");

    const sorvi_api = sorvi.createSorviAPI(b, .{
        .target = target,
        .api = .core,
        .extensions = &.{
            "core_v1",
            "mem_v1",
            "fs_v1",
            "kbm_v1",
            "audio_v1",
            "video_v1",
            "raster_v1",
        },
    });

    const sorvi_target = sorvi.resolveSorviTarget(b, target.query);

    const puredoom_dep = b.dependency("puredoom", .{});
    const puredoom_src = b.addWriteFiles().add("puredoom.c",
        \\#define DOOM_IMPLEMENTATION
        \\#include "PureDOOM.h"
    );
    const puredoom_lib = b.addLibrary(.{
        .name = "puredoom",
        .linkage = .static,
        .root_module = D: {
            const mod = b.createModule(.{
                .target = sorvi_target,
                .optimize = optimize,
                .link_libc = false,
                .sanitize_c = .off,
            });
            mod.addCSourceFiles(.{
                .files = &.{"puredoom.c"},
                .flags = &.{"-O0"}, // optimizations break rendering
                .root = puredoom_src.dirname(),
            });
            mod.addIncludePath(puredoom_dep.path(""));
            break :D mod;
        },
    });
    const puredoom_h = b.addTranslateC(.{
        .root_source_file = puredoom_dep.path("PureDOOM.h"),
        .target = sorvi_target,
        .optimize = optimize,
        .link_libc = false,
    });
    const puredoom = puredoom_h.createModule();
    puredoom.linkLibrary(puredoom_lib);

    const doom = sorvi.addSorviCore(b, .{
        .name = "doom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/doom.zig"),
            .single_threaded = true,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sorvi", .module = sorvi_api },
                .{ .name = "puredoom", .module = puredoom },
            },
        }),
    });
    doom.root_module.addAnonymousImport("doom1.wad", .{
        .root_source_file = puredoom_dep.path("doom1.wad"),
    });
    doom.fixup(b);

    const step = b.step("run", "Run doom in a reference frontend");
    step.dependOn(&sorvi.addRunSorviCore(b, frontend, doom).step);
}
