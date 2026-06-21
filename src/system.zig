//! system.zig -- Windows performance primitives for the AstroBWTv3 DERO miner.
//!
//! Provides:
//!   - Large-page (2 MB) allocation via SeLockMemoryPrivilege + VirtualAlloc
//!   - Thread-to-logical-CPU pinning via SetThreadAffinityMask
//!   - Thread priority elevation + power-throttling disable
//!   - Recommended affinity ordering for n mining threads
//!
//! All Win32 calls are made directly via `extern "kernel32"` / `extern "advapi32"`.
//! No third-party dependencies; pure Zig 0.14.1.
//!
//! Link flags (for standalone test exe):
//!   .tools\zig\zig.exe build-exe _system\test_system.zig -OReleaseFast -lc -ladvapi32 -lkernel32
//! When built via build.zig, kernel32 and advapi32 are pulled in automatically.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// ── Win32 base types ─────────────────────────────────────────────────────────
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const ULONG = windows.ULONG;
const SIZE_T = windows.SIZE_T;
const ULONG_PTR = windows.ULONG_PTR;
const LPVOID = windows.LPVOID;
const TRUE: BOOL = 1;
const FALSE: BOOL = 0;

// ── VirtualAlloc / VirtualFree flags ─────────────────────────────────────────
const MEM_COMMIT: DWORD = 0x00001000;
const MEM_RESERVE: DWORD = 0x00002000;
const MEM_RELEASE: DWORD = 0x00008000;
const MEM_LARGE_PAGES: DWORD = 0x20000000;
const PAGE_READWRITE: DWORD = 0x04;

// ── Thread priority constants ─────────────────────────────────────────────────
const THREAD_PRIORITY_HIGHEST: c_int = 2;
// const THREAD_PRIORITY_ABOVE_NORMAL: c_int = 1; // kept for reference

// ── SetThreadInformation / ThreadPowerThrottling ──────────────────────────────
// THREAD_INFORMATION_CLASS value 3 = ThreadPowerThrottling (processthreadsapi.h)
const ThreadPowerThrottling: c_int = 3;
const THREAD_POWER_THROTTLING_CURRENT_VERSION: ULONG = 1;
const THREAD_POWER_THROTTLING_EXECUTION_SPEED: ULONG = 0x1;

const THREAD_POWER_THROTTLING_STATE = extern struct {
    Version: ULONG,
    ControlMask: ULONG,
    StateMask: ULONG,
};

// ── Token / privilege constants ───────────────────────────────────────────────
const TOKEN_QUERY: DWORD = 0x0008;
const TOKEN_ADJUST_PRIVILEGES: DWORD = 0x0020;
const SE_PRIVILEGE_ENABLED: DWORD = 0x00000002;

// ERROR codes
const ERROR_SUCCESS: DWORD = 0;
const ERROR_NOT_ALL_ASSIGNED: DWORD = 1300;

const LUID = extern struct {
    LowPart: DWORD,
    HighPart: i32,
};

const LUID_AND_ATTRIBUTES = extern struct {
    Luid: LUID,
    Attributes: DWORD,
};

const TOKEN_PRIVILEGES = extern struct {
    PrivilegeCount: DWORD,
    Privileges: [1]LUID_AND_ATTRIBUTES,
};

// ── kernel32 declarations not in std ────────────────────────────────────────
extern "kernel32" fn GetCurrentThread() callconv(.winapi) HANDLE;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn SetPriorityClass(hProcess: HANDLE, dwPriorityClass: DWORD) callconv(.winapi) BOOL;
const HIGH_PRIORITY_CLASS: DWORD = 0x00000080;
extern "kernel32" fn VirtualAlloc(
    lpAddress: ?LPVOID,
    dwSize: SIZE_T,
    flAllocationType: DWORD,
    flProtect: DWORD,
) callconv(.winapi) ?LPVOID;
extern "kernel32" fn VirtualFree(
    lpAddress: ?LPVOID,
    dwSize: SIZE_T,
    dwFreeType: DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetLargePageMinimum() callconv(.winapi) SIZE_T;
extern "kernel32" fn SetThreadAffinityMask(
    hThread: HANDLE,
    dwThreadAffinityMask: ULONG_PTR,
) callconv(.winapi) ULONG_PTR;
extern "kernel32" fn SetThreadPriority(
    hThread: HANDLE,
    nPriority: c_int,
) callconv(.winapi) BOOL;
extern "kernel32" fn SetThreadInformation(
    hThread: HANDLE,
    ThreadInformationClass: c_int,
    ThreadInformation: *anyopaque,
    ThreadInformationSize: DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

// ── advapi32 declarations ─────────────────────────────────────────────────────
extern "advapi32" fn OpenProcessToken(
    ProcessHandle: HANDLE,
    DesiredAccess: DWORD,
    TokenHandle: *HANDLE,
) callconv(.winapi) BOOL;
extern "advapi32" fn LookupPrivilegeValueA(
    lpSystemName: ?[*:0]const u8,
    lpName: [*:0]const u8,
    lpLuid: *LUID,
) callconv(.winapi) BOOL;
extern "advapi32" fn AdjustTokenPrivileges(
    TokenHandle: HANDLE,
    DisableAllPrivileges: BOOL,
    NewState: *TOKEN_PRIVILEGES,
    BufferLength: DWORD,
    PreviousState: ?*TOKEN_PRIVILEGES,
    ReturnLength: ?*DWORD,
) callconv(.winapi) BOOL;
extern "advapi32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

// ── 1. enableLockMemoryPrivilege ──────────────────────────────────────────────
/// Enable SeLockMemoryPrivilege for the current process.
///
/// Returns true only if the privilege was actually granted (GetLastError == 0
/// after AdjustTokenPrivileges — NOT just the BOOL return, which is always TRUE
/// even when ERROR_NOT_ALL_ASSIGNED).
///
/// IMPORTANT: Requires the calling user to hold the "Lock pages in memory"
/// right.  To grant it on this machine:
///   1. Run `secpol.msc` as Administrator.
///   2. Local Policies > User Rights Assignment > Lock pages in memory.
///   3. Add Users/Groups button → add your account (or the miner service user).
///   4. Log off and back on (or reboot) — the right takes effect at next logon.
/// Without it, AdjustTokenPrivileges succeeds-but-lies; GetLastError returns
/// ERROR_NOT_ALL_ASSIGNED (1300), so this function returns false.
pub fn enableLockMemoryPrivilege() bool {
    var token: HANDLE = undefined;
    if (OpenProcessToken(
        GetCurrentProcess(),
        TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
        &token,
    ) == FALSE) return false;
    defer _ = CloseHandle(token);

    var luid: LUID = undefined;
    if (LookupPrivilegeValueA(null, "SeLockMemoryPrivilege", &luid) == FALSE) {
        return false;
    }

    var tp = TOKEN_PRIVILEGES{
        .PrivilegeCount = 1,
        .Privileges = [1]LUID_AND_ATTRIBUTES{.{
            .Luid = luid,
            .Attributes = SE_PRIVILEGE_ENABLED,
        }},
    };

    _ = AdjustTokenPrivileges(token, FALSE, &tp, @sizeOf(TOKEN_PRIVILEGES), null, null);
    // AdjustTokenPrivileges returns TRUE even when it cannot fully apply the
    // change (ERROR_NOT_ALL_ASSIGNED = 1300). We must check GetLastError.
    return GetLastError() == ERROR_SUCCESS;
}

// ── 2. allocLargePages / freeLargePages ──────────────────────────────────────
/// Allocate `size` bytes as large pages (typically 2 MB pages on x86-64).
///
/// - Rounds `size` up to the next multiple of GetLargePageMinimum().
/// - Requires that enableLockMemoryPrivilege() has previously returned true.
/// - Returns null on failure; caller should fall back to normal alloc.
///   On failure GetLastError() == 1314 means privilege not held;
///   == 1450 means insufficient contiguous physical memory (try after reboot).
pub fn allocLargePages(size: usize) ?[]align(4096) u8 {
    const page_min = GetLargePageMinimum();
    if (page_min == 0) return null; // large pages not supported on this CPU/OS

    const rounded = roundUp(size, page_min);
    const ptr = VirtualAlloc(
        null,
        rounded,
        MEM_RESERVE | MEM_COMMIT | MEM_LARGE_PAGES,
        PAGE_READWRITE,
    ) orelse return null;

    const bytes: [*]align(4096) u8 = @alignCast(@ptrCast(ptr));
    return bytes[0..rounded];
}

/// Free a buffer previously returned by allocLargePages.
/// Pass the exact slice you received; the length field is ignored by VirtualFree
/// (MEM_RELEASE requires dwSize == 0), but we accept the full slice for symmetry.
pub fn freeLargePages(buf: []align(4096) u8) void {
    _ = VirtualFree(@ptrCast(buf.ptr), 0, MEM_RELEASE);
}

// ── 3. pinThreadToLogical ─────────────────────────────────────────────────────
/// Pin the calling thread to a single logical processor `cpu` (0-based).
///
/// On i7-13700HX:
///   Logical  0..15  = P-core HT siblings, paired as (0,1),(2,3),(4,5)...,(14,15)
///   Logical 16..23  = E-cores (no HT)
///
/// SetThreadAffinityMask ignores calls that set bits outside the process affinity
/// mask, so out-of-range `cpu` values will silently no-op.
/// Raise the whole process to HIGH priority class (matches the C miner's `-p max`;
/// base priority 13, so HIGHEST threads reach 15 instead of 10 under NORMAL class).
pub fn setProcessHighPriority() void {
    _ = SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
}

pub fn pinThreadToLogical(cpu: u6) void {
    if (builtin.os.tag == .windows) {
        const mask: ULONG_PTR = @as(ULONG_PTR, 1) << cpu;
        _ = SetThreadAffinityMask(GetCurrentThread(), mask);
        return;
    }
    if (builtin.os.tag != .linux) return;

    // Linux — use std.os.linux.sched_setaffinity (raw syscall). cpu_set_t is a
    // fixed-size array of c_ulong sized by sigset_len (Linux's CPU_SETSIZE
    // is hard-coded to 1024 historically; glibc mirrors it). Set the bit for
    // `cpu` directly in the array, then sched_setaffinity self = 0.
    const SetLen: usize = @typeInfo(std.os.linux.cpu_set_t).array.len;
    var mask: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);
    const u: usize = @intCast(cpu);
    const word_idx: usize = u / @bitSizeOf(c_ulong);
    const bit_off: u6 = @intCast(u % @bitSizeOf(c_ulong));
    if (word_idx < SetLen) mask[word_idx] = (@as(c_ulong, 1)) << @intCast(bit_off);
    std.os.linux.sched_setaffinity(0, &mask) catch {};
}

// ── 4. setThreadHighPriority ──────────────────────────────────────────────────
/// Elevate the calling thread's scheduling priority and disable power throttling.
///
/// - SetThreadPriority(THREAD_PRIORITY_HIGHEST) — moves the thread into the
///   highest real-time-adjacent Windows priority bucket.
/// - SetThreadInformation(ThreadPowerThrottling, StateMask=0) — tells the
///   scheduler to disable execution-speed throttling for this thread.
///   StateMask=0 with ControlMask=EXECUTION_SPEED means "do not throttle."
///   This call may fail on older Windows 10 builds; failure is silently ignored.
pub fn setThreadHighPriority() void {
    _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);

    var pts = THREAD_POWER_THROTTLING_STATE{
        .Version = THREAD_POWER_THROTTLING_CURRENT_VERSION,
        .ControlMask = THREAD_POWER_THROTTLING_EXECUTION_SPEED,
        .StateMask = 0, // 0 = do NOT throttle
    };
    _ = SetThreadInformation(
        GetCurrentThread(),
        ThreadPowerThrottling,
        @ptrCast(&pts),
        @sizeOf(THREAD_POWER_THROTTLING_STATE),
    );
}

// ── 4b. enableVirtualTerminal ─────────────────────────────────────────────────
const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5; // (DWORD)-11
const STD_ERROR_HANDLE: DWORD = 0xFFFFFFF4; // (DWORD)-12
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;

/// Enable ANSI escape (virtual terminal) processing on stdout+stderr so the colored
/// status line renders on Windows 10+/Windows Terminal. Failure-silent (a redirected
/// or legacy console simply keeps its mode; the reporter's TTY check skips color there).
pub fn enableVirtualTerminal() void {
    for ([_]DWORD{ STD_OUTPUT_HANDLE, STD_ERROR_HANDLE }) |which| {
        const h = GetStdHandle(which);
        var mode: DWORD = 0;
        if (GetConsoleMode(h, &mode) == FALSE) continue;
        _ = SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
}

// ── 5. recommendedAffinityForThreads ─────────────────────────────────────────
/// Return an ordered list of logical CPU IDs for n mining threads.
///
/// Ordering rationale (AstroBWTv3 is memory/cache-heavy: suffix-array build,
/// RC4 in-place, 278-iter branch loop with CodeLUT):
///
///   1. Distinct physical cores first — one CPU per core, never two threads
///      sharing an L1/L2. Each CPU is the "first HT sibling" (comptime-pinned
///      even-halves on Intel where Linux numbers SMT pairs as (0,1) (2,3) …;
///      or the lowest-numbered logical within the siblings set on whatever the
///      kernel chose). Cycle through distinct physicals before adding any
///      second-thread siblings, so the per-thread cache footprint stays
///      independent.
///   2. HT siblings (comptime siblings of #1) — share L1/L2 with the
///      already-scheduled partner. Worst cache locality for this workload,
///      placed last so a small thread count avoids them.
///
/// Linux: probe `/sys/devices/system/cpu/cpu<N>/topology/thread_siblings_list`
/// in each cpu<N>'s siblings file; group by sibling set; pick the smallest
/// member of each group (in CI / arithmetic tests that picker also gives us
/// repeatability).
/// Windows + non-Linux + fallback on probe failure: use the original
/// i7-13700HX-shaped order below — preserves the prior behavior on those hosts.
///
/// Returns up to 24 entries; entries beyond n are 0-filled.
pub fn recommendedAffinityForThreads(n: usize) [24]u6 {
    // Probe on Linux, fall back to the original i7-shaped order otherwise.
    if (builtin.os.tag == .linux) {
        if (probeLinuxTopologyOrder()) |probed| {
            return orderFromProbed(probed, n);
        }
    }

    // i7-13700HX-shaped default (8 P + 8 E + 8 P-HT siblings). Preserves the
    // pre-Stage-2 behavior on Windows / non-Linux / --probe failures.
    const order = [24]u6{
        // 8 distinct P-core physical cores (even logicals = first HT sibling)
        0,  2,  4,  6,  8,  10, 12, 14,
        // 8 E-cores (no HT)
        16, 17, 18, 19, 20, 21, 22, 23,
        // 8 P-core HT siblings (share L1/L2 with their even partner above)
        1,  3,  5,  7,  9,  11, 13, 15,
    };

    var result = [_]u6{0} ** 24;
    const count = @min(n, 24);
    for (0..count) |i| {
        result[i] = order[i];
    }
    return result;
}

/// Parsed-topology ordering record. Each entry: a "first representative"
/// member of a thread-siblings group, followed by the *other* member(s) of
/// that group (i.e., HT siblings). Groups are visited in the order their
/// first-representative was discovered in /sys (typically ascending logical
/// IDs on x86_64 Linux).
const ProbedTopology = struct {
    /// Representative-of-group IDs in the order they were encountered. With
    /// SMT-2 + 2 groups per pair, this is the n/2 distinct physical cores.
    reps: [16]u6,
    rep_count: u6,

    /// The HT sibling of each rep_group[i]. Only filled when the group has 2
    /// members (SMT-2). Position-aligned with reps[]. Index i holds the sibling
    /// of reps[i]; 0 means "no sibling" (SMT disabled or single-thread core).
    siblings: [16]u6,
};

/// Probe `/sys/devices/system/cpu/cpu<N>/topology/thread_siblings_list` for
/// each logical CPU 0..nproc and group by sibling set. Returns null on any
/// open/read/parse failure (caller falls back to the i7-shaped order).
fn probeLinuxTopologyOrder() ?ProbedTopology {
    const allocator = std.heap.page_allocator;

    // Track which sibling groups we've already seen (by first-representative ID).
    var seen_first: [64]u6 = undefined;
    var seen_count: u6 = 0;

    var probed: ProbedTopology = .{
        .reps = .{0} ** 16,
        .rep_count = 0,
        .siblings = .{0} ** 16,
    };

    var cpu: usize = 0;
    while (cpu < 64) : (cpu += 1) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list", .{cpu}) catch continue;
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        defer _ = std.os.linux.close(fd);

        const buf = allocator.alloc(u8, 256) catch continue;
        defer allocator.free(buf);

        var total: usize = 0;
        var attempts: u8 = 0;
        while (total < buf.len - 1 and attempts < 4) : (attempts += 1) {
            const r = std.posix.read(fd, buf[total..buf.len - 1]) catch continue;
            if (r == 0) break;
            total += r;
        }
        const n = total;
        // Format on Linux/cgroup is "0,2\n" or "0-7\n" or "0,2,4\n" etc.
        // Returned contents NOT NUL-terminated by readAll.
        const slice = buf[0..@min(n, buf.len)];

        // Pick the smallest member (id) of the listed group → "representative".
        var group: [64]u6 = undefined;
        var group_n: usize = 0;
        var it = std.mem.splitScalar(u8, slice, ',');
        while (it.next()) |tok_raw| {
            const tok = std.mem.trim(u8, tok_raw, " \t\r\n");
            if (tok.len == 0) continue;
            // Handle "a-b" ranges.
            if (std.mem.indexOfScalar(u8, tok, '-')) |dash| {
                const lo = std.fmt.parseInt(u6, tok[0..dash], 10) catch continue;
                const hi = std.fmt.parseInt(u6, tok[dash + 1 ..], 10) catch continue;
                var k: u6 = lo;
                while (k <= hi) : (k += 1) {
                    if (group_n >= group.len) break;
                    group[group_n] = k;
                    group_n += 1;
                }
            } else {
                const v = std.fmt.parseInt(u6, tok, 10) catch continue;
                if (group_n >= group.len) continue;
                group[group_n] = v;
                group_n += 1;
            }
        }
        if (group_n == 0) continue;

        // Find the smallest member as "representative", and pick its top
        // sibling if there are ≥2 members.
        var rep: u6 = group[0];
        var k: usize = 1;
        while (k < group_n) : (k += 1) {
            if (group[k] < rep) rep = group[k];
        }

        // Skip already-seen groups.
        var already_seen = false;
        for (seen_first[0..seen_count]) |s| {
            if (s == rep) {
                already_seen = true;
                break;
            }
        }
        if (already_seen) continue;
        seen_first[seen_count] = rep;
        seen_count += 1;

        if (probed.rep_count >= probed.reps.len) break;
        probed.reps[probed.rep_count] = rep;
        probed.siblings[probed.rep_count] = if (group_n >= 2) blk: {
            // Pick the LARGEST member as the heavy-sharing HT sibling (most
            // kernels expose the second HT as the bigger logical ID).
            var m: u6 = group[1];
            var ki: usize = 2;
            while (ki < group_n) : (ki += 1) {
                if (group[ki] > m) m = group[ki];
            }
            break :blk m;
        } else 0;
        probed.rep_count += 1;

        // Stop once we have enough reps to cover downstream n requests.
        // The order array caps at 24 (16 reps + 16 sibs -> up to 32 IDs).
        if (probed.rep_count >= 16) break;
    }
    if (probed.rep_count == 0) return null;
    return probed;
}

/// Convert the probed topology into the [24]u6 first rep-only (always
/// distinct physical cores), then HT siblings. Capping mutates `n` from the
/// caller so we don't overflow distinct cores before adding sibs.
fn orderFromProbed(probed: ProbedTopology, n: usize) [24]u6 {
    var result = [_]u6{0} ** 24;
    var out: usize = 0;

    // First pass: emit distinct physical cores (reps) only.
    var i: usize = 0;
    while (i < probed.rep_count) : (i += 1) {
        if (out >= n or out >= result.len) break;
        result[out] = probed.reps[i];
        out += 1;
    }

    // Second pass: HT siblings of each rep. Only meaningful when n > rep_count
    // AND the rep had a sibling (SMT > 1). Fills the remaining slots.
    i = 0;
    while (i < probed.rep_count) : (i += 1) {
        if (out >= n or out >= result.len) break;
        if (probed.siblings[i] == 0) continue;
        result[out] = probed.siblings[i];
        out += 1;
    }
    return result;
}

// ── internal helpers ──────────────────────────────────────────────────────────
fn roundUp(value: usize, multiple: usize) usize {
    return (value + multiple - 1) / multiple * multiple;
}

// ── basic self-tests (run with `zig build test`) ───────────────────────────────
test "roundUp" {
    try std.testing.expectEqual(@as(usize, 4096), roundUp(1, 4096));
    try std.testing.expectEqual(@as(usize, 4096), roundUp(4096, 4096));
    try std.testing.expectEqual(@as(usize, 8192), roundUp(4097, 4096));
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), roundUp(1, 2 * 1024 * 1024));
}

test "recommendedAffinityForThreads ordering" {
    if (builtin.os.tag == .linux) {
        // Zen 5 + SMT-2 + 16 P-cores + 0 E-cores.
        // Smallest-member per thread-siblings group on Linux x86_64 = even
        // logicals 0,2,4,...,30. Probe should yield that.
        const map = recommendedAffinityForThreads(20);
        // First get the 16 distinct physical cores. Then siblings of those.
        try std.testing.expectEqual(@as(u6, 0), map[0]);
        try std.testing.expectEqual(@as(u6, 2), map[1]);
        try std.testing.expectEqual(@as(u6, 30), map[15]);
        // 17th..20th: HT siblings (1, 3, 5, 7) — only emit if the request
        // exceeds distinct cores.
        try std.testing.expectEqual(@as(u6, 1), map[16]);
        try std.testing.expectEqual(@as(u6, 3), map[17]);
        try std.testing.expectEqual(@as(u6, 5), map[18]);
        try std.testing.expectEqual(@as(u6, 7), map[19]);
        // Beyond n should be zero (result is 24-entry)
        try std.testing.expectEqual(@as(u6, 0), map[20]);
        return;
    }
    // Fallback / Windows / non-Linux path: i7-shaped pre-Stage-2 order.
    const map = recommendedAffinityForThreads(10);
    try std.testing.expectEqual(@as(u6, 0), map[0]);
    try std.testing.expectEqual(@as(u6, 2), map[1]);
    try std.testing.expectEqual(@as(u6, 14), map[7]);
    try std.testing.expectEqual(@as(u6, 16), map[8]);
    try std.testing.expectEqual(@as(u6, 17), map[9]);
    try std.testing.expectEqual(@as(u6, 0), map[10]);
}
