const std = @import("std");

fn tubBinary(b: *std.Build, arch: std.Target.Cpu.Arch, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const name = switch (arch) {
        .aarch64 => "BOOTAA64",
        .x86_64  => "BOOTX64",
        else => @panic("unknown architecture: modify tubBinary, test, and send a patch!"),
    };

    const target = b.resolveTargetQuery(.{
        .os_tag = .uefi,
        .cpu_arch = arch,
    });

    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tub.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });
}

fn scdoc(b: *std.Build, from: []const u8, to: []const u8) *std.Build.Step.InstallFile {
    const cmd  = b.addSystemCommand(&.{"scdoc"});
    const path = b.path(from);
    cmd.addFileInput(path);
    cmd.setStdIn(.{ .lazy_path = path });
    const out = cmd.captureStdOut(.{});
    return b.addInstallFile(out, to);
}

const defaultArchitectures = [_]std.Target.Cpu.Arch{
    .aarch64, .x86_64,
};
pub fn build(b: *std.Build) void {
    // BOOT*.efi
    const arches = b.option([]std.Target.Cpu.Arch, "arch", "architecture(s) to build for")
        orelse &defaultArchitectures;
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .small
    });
    for (arches) |arch| {
        const exe = tubBinary(b, arch, optimize);
        b.installArtifact(exe);
    }

    // docs
    if (b.option(bool, "docs", "build manual pages using scdoc") orelse false) {
        const tub5 = scdoc(b, "docs/tub.5.scd", "tub.5");
        const tub7 = scdoc(b, "docs/tub.7.scd", "tub.7");
        b.getInstallStep().dependOn(&tub5.step);
        b.getInstallStep().dependOn(&tub7.step);
    }
}
