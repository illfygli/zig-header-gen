const Builder = @import("std").build.Builder;

const std = @import("std");
const warn = std.debug.print;

// This build.zig is only used as an example of using header_gen

pub fn build(b: *Builder) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // HEADER GEN BUILD STEP
    const exe = b.addExecutable(.{
        .name = "example",
        .root_source_file = .{
            .path = "src/example/exports.zig",
        },
        .optimize = optimize,
        .target = target,
    });

    const header_gen_mod = b.addModule(
        "header_gen",
        .{ .source_file = .{ .path = "src/header_gen.zig" } },
    );

    exe.addModule("header_gen", header_gen_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("headergen", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
