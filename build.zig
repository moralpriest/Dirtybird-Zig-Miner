const std = @import("std");
const builtin = @import("builtin");

// Suffix-array dependencies, compiled as C/C++ and linked through Zig's C interop:
//   * libsais  -- canonical exact suffix array (the fallback path)
//   * the v1.14 "descriptor" suffix array -- exact, structure-aware, the default
//     backend; compiled from the dirtybird reference source and exposed via a
//     small extern "C" wrapper.
// The suffix array is most of the per-hash cost, so these are built with the
// reference's release flags (-DNDEBUG drops the libsais/v114 asserts from the hot
// path). -Dpgo=gen|use enables an optional two-pass profile-guided build.
fn addSaDeps(m: *std.Build.Module, b: *std.Build, pgo: []const u8, profile_rt: ?[]const u8) void {
    // SA objects link through libc (libsais, sha_stub.c) and libc++ (v114_*.cpp).
    m.link_libc = true;
    m.link_libcpp = true;

    var cf: std.ArrayList([]const u8) = .empty;
    var cppf: std.ArrayList([]const u8) = .empty;
    cf.appendSlice(b.allocator, &.{ "-O3", "-DNDEBUG", "-fomit-frame-pointer", "-finline-functions", "-fno-sanitize=all" }) catch @panic("oom");
    cppf.appendSlice(b.allocator, &.{ "-O3", "-DNDEBUG", "-fomit-frame-pointer", "-finline-functions", "-fno-vectorize", "-fno-slp-vectorize", "-fno-sanitize=all", "-std=c++17" }) catch @panic("oom");

    if (std.mem.eql(u8, pgo, "gen")) {
        // Instrumented build: writes profiles to _pgo/ when the binary runs.
        cf.append(b.allocator, "-fprofile-generate=_pgo") catch @panic("oom");
        cppf.append(b.allocator, "-fprofile-generate=_pgo") catch @panic("oom");
        // Instrumentation needs your Clang profile runtime (libclang_rt.profile-*).
        // Provide it with -Dprofile_rt=<path>, e.g. the one shipped by your LLVM/MinGW.
        if (profile_rt) |p| {
            // std.Build.addObjectFile/LazyPath doesn't accept absolute paths via simple
            // `b.path`. `cwd_relative` is the documented escape hatch.
            if (std.fs.path.isAbsolute(p)) {
                m.addObjectFile(.{ .cwd_relative = p });
            } else {
                m.addObjectFile(b.path(p));
            }
        } else {
            std.debug.print(
                "build: -Dpgo=gen requires -Dprofile_rt=<path to libclang_rt.profile-x86_64.a>\n",
                .{},
            );
            @panic("missing -Dprofile_rt for -Dpgo=gen");
        }
    } else if (std.mem.eql(u8, pgo, "use")) {
        // Fold a previously-merged profile (llvm-profdata merge _pgo/*.profraw) back in.
        cf.appendSlice(b.allocator, &.{ "-fprofile-use=_pgo/merged.profdata", "-flto" }) catch @panic("oom");
        cppf.appendSlice(b.allocator, &.{ "-fprofile-use=_pgo/merged.profdata", "-flto" }) catch @panic("oom");
    }

    m.addCSourceFile(.{ .file = b.path("vendor/libsais/libsais.c"), .flags = cf.items });
    m.addCSourceFile(.{ .file = b.path("vendor/v114/sha_stub.c"), .flags = cf.items });
    m.addCSourceFile(.{ .file = b.path("vendor/v114/v114_stubs.cpp"), .flags = cppf.items });
    m.addCSourceFile(.{ .file = b.path("vendor/v114/v114_wrapper.cpp"), .flags = cppf.items });
    m.addIncludePath(b.path("vendor/libsais"));
    m.addIncludePath(b.path("vendor/v114"));
}

pub fn build(b: *std.Build) void {
    // Default to the best-performance configuration so a bare `zig build` (no flags)
    // produces the fastest binary: ReleaseFast, the x86_64_v3+sha baseline on x86_64
    // hosts (the legacy-SSE SHA path that beats `native`), and PGO when a local profile
    // exists. All overridable via -Doptimize / -Dtarget / -Dcpu / -Dpgo.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    var default_query: std.Target.Query = .{};
    if (builtin.target.cpu.arch == .x86_64) default_query = .{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .cpu_features_add = std.Target.x86.featureSet(&.{.sha}),
    };
    const target = b.standardTargetOptions(.{ .default_target = default_query });

    const profile_rt = b.option([]const u8, "profile_rt", "Path to libclang_rt.profile-x86_64.a (required for -Dpgo=gen)");
    const pgo_opt = b.option([]const u8, "pgo", "PGO for the C/C++ suffix array: gen | use | off (default: use when _pgo/merged.profdata exists on x86_64)") orelse "use";

    // Resolve PGO: "use" applies only on x86_64 with the profile present; otherwise fall
    // back to plain ReleaseFast (byte-identical hash, just not profile-optimized) so a
    // bare build never fails on a fresh clone, a non-x86 target, or in CI.
    var pgo = pgo_opt;
    if (std.mem.eql(u8, pgo_opt, "use")) {
        const have_profile = blk: {
            b.build_root.handle.access(b.graph.io, "_pgo/merged.profdata", .{}) catch break :blk false;
            break :blk true;
        };
        if (!(have_profile and target.result.cpu.arch == .x86_64)) pgo = "off";
    }
    std.debug.print("build: optimize={s} cpu={s} pgo={s}\n", .{ @tagName(optimize), target.result.cpu.model.name, pgo });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zig-miner",
        .root_module = exe_mod,
    });
    addSaDeps(exe_mod, b, pgo, profile_rt);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run the miner");
    run_step.dependOn(&run_cmd.step);

    // ---- synthetic hashrate benchmark (no network; used by the Benchmarks CI).
    // Usage: zig build bench -- <threads> <seconds> <aff 0/1> <affmode>
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    addSaDeps(bench_mod, b, pgo, profile_rt);
    b.installArtifact(bench);
    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run the synthetic hashrate benchmark");
    bench_step.dependOn(&bench_run.step);
}
