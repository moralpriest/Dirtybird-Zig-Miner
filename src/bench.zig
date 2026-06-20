//! bench.zig -- multi-threaded hashrate benchmark (no networking).
//!   bench [threads] [seconds]
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const pow = @import("pow.zig");
const system = @import("system.zig");
const pages = @import("pages.zig");

// `std.time.milliTimestamp`/`std.time.sleep` were removed in Zig 0.16. Use
// clock_gettime(CLOCK_MONOTONIC) + nanosleep directly via libc (we already link
// libc for the SA objects).
fn nowMs() i128 {
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1000 + @divTrunc(@as(i128, ts.nsec), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    const req = posix.timespec{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .nsec = @intCast(@rem(ms, 1000) * std.time.ns_per_ms),
    };
    _ = posix.system.nanosleep(&req, null);
}

const Ctx = struct {
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    seed: u64 = 12345,
    aff: bool = false,
    affmode: u8 = 0,
    hp: bool = false,
    nthreads: usize = 1,
};

// A/B affinity maps for 10 threads on i7-13700HX (logical 0..15 = P-core HT
// pairs (0,1),(2,3)..; 16..23 = E-cores).
const AFF_MAPS = [_][10]u6{
    .{ 0, 2, 4, 6, 8, 10, 12, 14, 16, 17 }, // 0: 8 distinct P + 2 E (same E-cluster)
    .{ 0, 2, 4, 6, 8, 10, 12, 14, 1, 3 }, // 1: 8 distinct P + 2 HT siblings
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, // 2: 5 P-cores fully HT (10 logical)
    .{ 0, 2, 4, 6, 8, 10, 12, 14, 16, 18 }, // 3: 8 P + 2 E (same cluster, spread)
    .{ 0, 2, 4, 6, 8, 10, 12, 14, 16, 20 }, // 4: 8 P + 2 E from DIFFERENT clusters
    .{ 0, 2, 4, 6, 8, 10, 12, 14, 18, 22 }, // 5: 8 P + 2 E diff clusters (alt)
};

fn worker(ctx: *Ctx, tid: usize) void {
    // Affinity / priority / large-page helpers are Windows-only; comptime-guard so
    // the bench cross-compiles and runs (unpinned) on Linux/macOS too.
    if (comptime builtin.os.tag == .windows) {
        if (ctx.aff) {
            const cpu: u6 = if (ctx.nthreads == 10) AFF_MAPS[ctx.affmode][tid] else system.recommendedAffinityForThreads(ctx.nthreads)[tid];
            system.pinThreadToLogical(cpu);
            system.setThreadHighPriority();
        }
    }
    var large_backing: ?pages.PageBacking = null;
    const w: *pow.Worker = blk: {
        if (ctx.hp) {
            if (pages.allocHugeBacking(@sizeOf(pow.Worker))) |backing| {
                large_backing = backing;
                break :blk @ptrCast(@alignCast(backing.bytes.ptr));
            }
        }
        break :blk std.heap.page_allocator.create(pow.Worker) catch return;
    };
    w.* = .{};
    defer {
        w.deinitSA();
        if (large_backing) |backing| {
            pages.freeHugeBacking(backing);
        } else std.heap.page_allocator.destroy(w);
    }
    var prng = std.Random.DefaultPrng.init(ctx.seed +% tid);
    var blob: [48]u8 = undefined;
    prng.random().bytes(&blob);
    blob[47] = @truncate(tid);
    var out: [32]u8 = undefined;
    var local: u64 = 0;
    while (!ctx.stop.load(.monotonic)) {
        std.mem.writeInt(u32, blob[43..47], @truncate(local), .big);
        pow.hash(&blob, &out, w) catch {};
        local += 1;
        if (local & 31 == 0) _ = ctx.count.fetchAdd(32, .monotonic);
    }
    _ = ctx.count.fetchAdd(local & 31, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(a);

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    defer arg_it.deinit();
    var first = true;
    while (arg_it.next()) |arg| {
        if (first) {
            first = false;
            continue; // skip argv[0]
        }
        try args_list.append(a, arg);
    }
    const args = try args_list.toOwnedSlice(a);
    defer a.free(args);
    const nthreads = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else (std.Thread.getCpuCount() catch 4);
    const secs = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 10;
    const aff = if (args.len > 3) (args[3][0] != '0' or args[3].len > 1) else false;
    const affmode: u8 = if (args.len > 4) (std.fmt.parseInt(u8, args[4], 10) catch 0) else 0;
    const hp = if (args.len > 5) (args[5][0] != '0') else false;

    var ctx = Ctx{ .aff = aff, .affmode = affmode, .hp = hp, .nthreads = nthreads };
    if (comptime builtin.os.tag == .windows) {
        if (aff or hp) {
            _ = system.enableLockMemoryPrivilege();
            if (aff) {
                system.setProcessHighPriority();
                std.debug.print("[affinity ON mode={d}, HIGH priority class]\n", .{affmode});
            }
        }
    }
    if (hp and builtin.os.tag == .linux) std.debug.print("[huge-pages THP requested]\n", .{});
    const threads = try a.alloc(std.Thread, nthreads);
    defer a.free(threads);

    const t0 = nowMs();
    for (threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, worker, .{ &ctx, i });
    sleepMs(secs * 1000);
    ctx.stop.store(true, .monotonic);
    for (threads) |t| t.join();

    const dt = @as(f64, @floatFromInt(nowMs() - t0)) / 1000.0;
    const total = ctx.count.load(.monotonic);
    const khs = @as(f64, @floatFromInt(total)) / dt / 1000.0;
    std.debug.print("bench: {d} threads, {d:.1}s, {d} hashes -> {d:.2} KH/s total ({d:.3} KH/s/thread)\n", .{ nthreads, dt, total, khs, khs / @as(f64, @floatFromInt(nthreads)) });
}
