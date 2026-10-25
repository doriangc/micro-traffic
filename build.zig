const std = @import("std");
const Build = std.Build;

const sokol_build = @import("sokol");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_webgpu = b.option(bool, "wgpu", "Build for WebGPU instead of WebGL2") orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    const sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .wgpu = use_webgpu,
    });
    const emsdk = sokol.builder.dependency("emsdk", .{});

    exe_mod.addImport("sokol", sokol.module("sokol"));

    // Declared up front so both branches can use it
    const run_step = b.step("run", "Run the app");

    b.step("install-emsdk", "Install Emscripten SDK")
        .dependOn(sokol_build.emSdkInstallStep(b, emsdk, .{}));

    if (!target.result.cpu.arch.isWasm()) {
        // for native platforms, build into a regular executable
        const exe = b.addExecutable(.{
            .name = "micro_traffic",
            .root_module = exe_mod,
        });

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);

        const exe_tests = b.addTest(.{
            .root_module = exe.root_module,
        });

        const test_step = b.step("test", "Run tests");
        const run_exe_tests = b.addRunArtifact(exe_tests);
        test_step.dependOn(&run_exe_tests.step);
    } else {
        // for WASM, need to build the Zig code as static library, since linking happens via emcc
        const example_step = b.addLibrary(.{
            .name = "micro_traffic",
            .root_module = exe_mod,
        });

        const link_step = try sokol_build.emLinkStep(b, .{
            .lib_main = example_step,
            .target = target,
            .optimize = optimize,
            .emsdk = emsdk,
            .use_webgpu = use_webgpu,
            .use_webgl2 = !use_webgpu,
            .use_emmalloc = false,
            .use_filesystem = true,
            .shell_file_path = sokol.path("src/sokol/web/shell.html"),
            .extra_args = &.{
                "-sSTACK_SIZE=512KB",
                "-pthread",
                "-sPTHREAD_POOL_SIZE=4",
                "-sINITIAL_MEMORY=64MB",
            },
        });
        b.getInstallStep().dependOn(&link_step.step);

        const run = sokol_build.emRunStep(b, .{ .name = example_step.name, .emsdk = emsdk });
        run.step.dependOn(&link_step.step);
        run_step.dependOn(&run.step);
    }
}
