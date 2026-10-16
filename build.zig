const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
    const app_name = "target_finder";

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
            .{ .name = "sdl-backend", .module = dvui_dep.module("sdl3") },
        },
    });

    // mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    // mod.addImport("sdl-backend", dvui_dep.module("sdl3")); // for zls

    const exe = b.addExecutable(.{ .name = app_name, .root_module = mod });

    b.installArtifact(exe);

    const compile_step = b.step("compile Target Finder", "Compile Target Finder");
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(compile_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(compile_step);

    const run_step = b.step(app_name, "Run " ++ app_name);
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_cmd = b.addRunArtifact(b.addTest(.{ .root_module = mod, .name = "test-" ++ app_name }));
    const test_step = b.step("test", "Test " ++ app_name);

    test_step.dependOn(&test_cmd.step);
}
