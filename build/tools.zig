// build/tools.zig — CSS/Tailwind and toolchain setup.

const std = @import("std");

pub fn addTools(b: *std.Build) void {
    // ── CSS: Tailwind v4 auto-download + compile ────────────────────────────
    const host_target = b.graph.host.result;
    const tw_os: []const u8 = switch (host_target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => "unsupported",
    };
    const tw_arch: []const u8 = switch (host_target.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => "unsupported",
    };
    const ensure_tw = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "test -x tools/tailwindcss || " ++
                "(mkdir -p tools && echo 'Downloading Tailwind CSS standalone CLI...' && " ++
                "curl -sLo tools/tailwindcss " ++
                "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-{s}-{s} && " ++
                "chmod +x tools/tailwindcss && echo 'Done.')",
            .{ tw_os, tw_arch },
        ),
    });
    const run_tw = b.addSystemCommand(&.{
        "tools/tailwindcss", "--input",           "examples/site/public/input.css",
        "--output",          "examples/site/public/styles.css", "--minify",
    });
    run_tw.step.dependOn(&ensure_tw.step);
    const css_step = b.step("css", "Compile Tailwind v4 → public/styles.css");
    css_step.dependOn(&run_tw.step);

    // ── `zig build setup` — download toolchain dependencies ─────────────────
    const setup_step = b.step("setup", "Download toolchain dependencies (Tailwind CLI)");
    setup_step.dependOn(&ensure_tw.step);
}
