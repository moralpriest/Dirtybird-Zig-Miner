const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");

const CpuidLeaf = struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
};

pub const Xcr0 = struct {
    sse: bool = false,
    ymm: bool = false,
    opmask: bool = false,
    zmm_hi256: bool = false,
    hi16_zmm: bool = false,

    fn fromRaw(raw: u32) Xcr0 {
        return .{
            .sse = isSet(raw, 1),
            .ymm = isSet(raw, 2),
            .opmask = isSet(raw, 5),
            .zmm_hi256 = isSet(raw, 6),
            .hi16_zmm = isSet(raw, 7),
        };
    }
};

pub const Brand = struct {
    buf: [48]u8 = [_]u8{0} ** 48,
    len: usize = 0,

    pub fn slice(self: *const Brand) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const CpuReport = struct {
    brand: Brand = .{},
    avx2: bool = false,
    avx512: bool = false,
    avx512bw: bool = false,
    avx512vl: bool = false,
    avx512vnni: bool = false,
    sha: bool = false,
    build_sha_avx2: bool = buildHasShaAvx2(),

    pub fn brandSlice(self: *const CpuReport) []const u8 {
        const b = self.brand.slice();
        return if (b.len == 0) "unknown CPU" else b;
    }
};

pub fn detect() CpuReport {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => detectX86(),
        else => .{},
    };
}

pub fn log(report: CpuReport) void {
    console.logLine("INFO", "CPU: {s}", .{report.brandSlice()});
    console.logLine("INFO", "Features: avx2 {s} | avx512 {s} | sha {s}", .{
        yesNo(report.avx2),
        yesNo(report.avx512),
        yesNo(report.sha),
    });
    console.logLine("INFO", "Fast path: SHA-NI+AVX2 build {s}; AVX512 mining path No", .{yesNo(report.build_sha_avx2)});
}

pub fn yesNo(v: bool) []const u8 {
    return if (v) "Yes" else "No";
}

pub fn sanitizeBrand(raw: [48]u8) Brand {
    var out: Brand = .{};
    var pending_space = false;
    for (raw) |c| {
        const is_space = c == 0 or c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            if (out.len > 0) pending_space = true;
            continue;
        }
        if (pending_space and out.len < out.buf.len) {
            out.buf[out.len] = ' ';
            out.len += 1;
        }
        pending_space = false;
        if (out.len < out.buf.len) {
            out.buf[out.len] = c;
            out.len += 1;
        }
    }
    if (out.len > 0 and out.buf[out.len - 1] == ' ') out.len -= 1;
    return out;
}

pub fn computeAvx2Usable(cpu_avx2: bool, xcr0: Xcr0) bool {
    return cpu_avx2 and xcr0.sse and xcr0.ymm;
}

pub fn computeAvx512Usable(cpu_avx512f: bool, xcr0: Xcr0) bool {
    return cpu_avx512f and xcr0.sse and xcr0.ymm and xcr0.opmask and xcr0.zmm_hi256 and xcr0.hi16_zmm;
}

fn detectX86() CpuReport {
    if (builtin.zig_backend == .stage2_c) return .{};

    const leaf0 = cpuid(0, 0);
    const max_leaf = leaf0.eax;
    const max_ext = cpuid(0x80000000, 0).eax;

    var raw_brand = [_]u8{0} ** 48;
    if (max_ext >= 0x80000004) {
        var off: usize = 0;
        for ([_]u32{ 0x80000002, 0x80000003, 0x80000004 }) |leaf_id| {
            const leaf = cpuid(leaf_id, 0);
            writeRegBytes(raw_brand[off..][0..4], leaf.eax);
            writeRegBytes(raw_brand[off + 4 ..][0..4], leaf.ebx);
            writeRegBytes(raw_brand[off + 8 ..][0..4], leaf.ecx);
            writeRegBytes(raw_brand[off + 12 ..][0..4], leaf.edx);
            off += 16;
        }
    }

    var leaf1: CpuidLeaf = .{};
    if (max_leaf >= 1) leaf1 = cpuid(1, 0);
    const xsave = isSet(leaf1.ecx, 26);
    const osxsave = isSet(leaf1.ecx, 27);
    const avx = isSet(leaf1.ecx, 28);
    const xcr0 = if (xsave and osxsave and avx) Xcr0.fromRaw(xgetbv0()) else Xcr0{};

    var leaf7: CpuidLeaf = .{};
    if (max_leaf >= 7) leaf7 = cpuid(7, 0);

    const cpu_avx2 = isSet(leaf7.ebx, 5);
    const cpu_avx512f = isSet(leaf7.ebx, 16);
    const avx512_usable = computeAvx512Usable(cpu_avx512f, xcr0);

    return .{
        .brand = sanitizeBrand(raw_brand),
        .avx2 = computeAvx2Usable(cpu_avx2, xcr0),
        .avx512 = avx512_usable,
        .avx512bw = avx512_usable and isSet(leaf7.ebx, 30),
        .avx512vl = avx512_usable and isSet(leaf7.ebx, 31),
        .avx512vnni = avx512_usable and isSet(leaf7.ecx, 11),
        .sha = isSet(leaf7.ebx, 29),
    };
}

fn cpuid(leaf_id: u32, subid: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (subid),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn xgetbv0() u32 {
    return asm volatile (
        \\ xor %%ecx, %%ecx
        \\ xgetbv
        : [_] "={eax}" (-> u32),
        :
        : .{ .edx = true, .ecx = true }
    );
}

inline fn isSet(value: u32, bit: u5) bool {
    return (value & (@as(u32, 1) << bit)) != 0;
}

inline fn writeRegBytes(dest: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, dest, value, .little);
}

fn buildHasShaAvx2() bool {
    return builtin.cpu.arch == .x86_64 and
        std.Target.x86.featureSetHasAll(builtin.cpu.features, .{ .sha, .avx2 });
}

test "brand string is trimmed and collapses interior nul bytes" {
    var raw = [_]u8{0} ** 48;
    @memcpy(raw[0.."  Test CPU".len], "  Test CPU");
    @memcpy(raw[12 .. "Model  ".len + 12], "Model  ");

    const brand = sanitizeBrand(raw);

    try std.testing.expectEqualStrings("Test CPU Model", brand.slice());
}

test "avx512 usability requires CPU bits and OS zmm state" {
    const with_zmm = Xcr0{
        .sse = true,
        .ymm = true,
        .opmask = true,
        .zmm_hi256 = true,
        .hi16_zmm = true,
    };
    const without_zmm = Xcr0{
        .sse = true,
        .ymm = true,
        .opmask = false,
        .zmm_hi256 = false,
        .hi16_zmm = false,
    };

    try std.testing.expect(computeAvx512Usable(true, with_zmm));
    try std.testing.expect(!computeAvx512Usable(true, without_zmm));
    try std.testing.expect(!computeAvx512Usable(false, with_zmm));
}

test "avx2 usability requires CPU bit and OS ymm state" {
    try std.testing.expect(computeAvx2Usable(true, .{ .sse = true, .ymm = true }));
    try std.testing.expect(!computeAvx2Usable(true, .{ .sse = true, .ymm = false }));
    try std.testing.expect(!computeAvx2Usable(false, .{ .sse = true, .ymm = true }));
}
