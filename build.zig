const std = @import("std");
const update = @import("update.zig");
const GitDependency = update.GitDependency;
fn update_step(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
    const deps = &.{
        GitDependency{
            // portaudio
            .url = "https://github.com/nat3Github/zig-lib-portaudio-dev-fork",
            .branch = "main",
        },
        GitDependency{
            // tailwind
            .url = "https://github.com/nat3Github/zig-lib-tailwind-colors",
            .branch = "master",
        },
        GitDependency{
            // icons
            .url = "https://github.com/nat3Github/zig-lib-icons",
            .branch = "main",
        },
        GitDependency{
            // dvui
            .url = "https://github.com/nat3Github/zig-lib-dvui-dev-fork",
            .branch = "dvui-synth",
        },
        GitDependency{
            // fifoasync
            .url = "https://github.com/nat3Github/zig-lib-fifoasync",
            .branch = "rt-sched",
        },
    };
    try update.update_dependency(step.owner.allocator, deps);
}

pub fn build(b: *std.Build) void {
    const step = b.step("update", "update git dependencies");
    step.makeFn = update_step;
    // if (true) return;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app = b.addExecutable(.{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    b.installArtifact(app);
    add_dependencies(b, app.root_module, target, optimize);

    const run_cmd1 = b.addRunArtifact(app);
    run_cmd1.step.dependOn(b.getInstallStep());
    const step_run = b.step("run", "Run the app");
    step_run.dependOn(&run_cmd1.step);

    const test1 = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
    });
    add_dependencies(b, test1.root_module, target, optimize);
    b.installArtifact(test1);
    const test1_run = b.addRunArtifact(test1);
    test1_run.step.dependOn(b.getInstallStep());
    const step_test = b.step("test", "test app");
    step_test.dependOn(&test1_run.step);
}

pub fn add_dependencies(
    b: *std.Build,
    root_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // const serialization_mod = b.dependency("serialization", .{
    //     .target = target,
    //     .optimize = optimize,
    // }).module("serialization");

    // const sqlite3_dep = b.dependency("sqlite3", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const sqlite3_mod = sqlite3_dep.module("sqlite3");
    // portaudio
    const portaudio_dep = b.dependency("portaudio", .{
        .optimize = optimize,
        .target = target,
    });

    // z2d
    // const z2d_mod = b.dependency("z2d", .{
    //     .optimize = optimize,
    //     .target = target,
    // }).module("z2d");

    // fifoasync
    const fifoasync_mod = b.dependency("fifoasync", .{
        .optimize = optimize,
        .target = target,
    }).module("fifoasync");

    const icons_module = b.dependency("icons", .{
        .target = target,
        .optimize = optimize,
    }).module("icons");

    const dvui_mod = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
    }).module("dvui_sdl3");

    const tailwind_module = b.dependency("tailwind", .{
        .target = target,
        .optimize = optimize,
    }).module("tailwind");

    root_mod.addImport("icons", icons_module);
    root_mod.addImport("dvui", dvui_mod);
    root_mod.addImport("tailwind", tailwind_module);
    root_mod.addImport("portaudio", portaudio_dep.module("portaudio"));
    // root_mod.addImport("z2d", z2d_mod);
    root_mod.addImport("fifoasync", fifoasync_mod);
}

test "test all refs" {
    std.testing.refAllDeclsRecursive(@This());
}
