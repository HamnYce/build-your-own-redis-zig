const std = @import("std");

pub fn build(b: *std.Build) void {
    const build_client = b.option(bool, "C", "Builds the client if present, else builds the server") orelse false;

    var exe: *std.Build.Step.Compile = undefined;

    if (build_client) {
        exe = b.addExecutable(.{
            .name = "redis-client",
            .root_source_file = b.path("src/client.zig"),
            .target = b.graph.host,
        });
    } else {
        exe = b.addExecutable(.{
            .name = "redis-cli",
            .root_source_file = b.path("src/server.zig"),
            .target = b.graph.host,
        });
    }

    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
