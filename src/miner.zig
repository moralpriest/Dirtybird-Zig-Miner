//! miner.zig -- mining thread: per-thread nonce search over the current job.
const std = @import("std");
const builtin = @import("builtin");
const pow = @import("pow.zig");
const difficulty = @import("difficulty.zig");
const state = @import("state.zig");
const system = @import("system.zig");
const MinerState = state.MinerState;
const BLOB_LEN = state.BLOB_LEN;

pub const NONCE_OFFSET = 43; // bytes 43..46, big-endian
pub const THREAD_ID_OFFSET = 47;

fn sleepMs(ms: u64) void {
    const req = std.posix.timespec{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .nsec = @intCast(@rem(ms, 1000) * std.time.ns_per_ms),
    };
    _ = std.posix.system.nanosleep(&req, null);
}

fn toHex(bytes: []const u8, out: []u8) void {
    const h = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = h[b >> 4];
        out[i * 2 + 1] = h[b & 0xf];
    }
}

inline fn writeNonce(blob: *[BLOB_LEN]u8, nonce: u32) void {
    blob[NONCE_OFFSET + 0] = @truncate(nonce >> 24);
    blob[NONCE_OFFSET + 1] = @truncate(nonce >> 16);
    blob[NONCE_OFFSET + 2] = @truncate(nonce >> 8);
    blob[NONCE_OFFSET + 3] = @truncate(nonce);
}

/// Mining thread entry point. Processes TWO nonces per iteration via the batched
/// `pow.hash2`, which interleaves the two latency-bound SHA-256 streams on SHA-NI
/// (~1.3x on the final-SHA stage -> ~5-8% overall vs single-stream). `w0`/`w1` are
/// this thread's two private scratch workers (one per lane).
pub fn mineThread(s: *MinerState, tid: usize, w0: *pow.Worker, w1: *pow.Worker) void {
    // Pin to a dedicated logical CPU (P-cores first, then E-cores; HT siblings
    // last) and disable power throttling -- AstroBWTv3 is memory/cache-bound, so
    // distinct physical cores beat HT siblings (measured +12% over the default
    // scheduler, and HT-sibling packing is ~25% worse).
    if (builtin.os.tag == .windows) {
        const map = system.recommendedAffinityForThreads(s.nthreads);
        system.pinThreadToLogical(map[@min(tid, 23)]);
        system.setThreadHighPriority();
    }

    var blob0: [BLOB_LEN]u8 = undefined;
    var blob1: [BLOB_LEN]u8 = undefined;
    var target: [32]u8 = undefined;
    var out0: [32]u8 = undefined;
    var out1: [32]u8 = undefined;
    var jbuf: [state.MAX_JOBID]u8 = undefined;
    var local_hashes: i64 = 0;

    // Wait until connected with a job. Mine as soon as a job arrives (like tnn) --
    // do NOT gate on difficulty>0: the daemon validates submits, and difficulty==0
    // yields an accept-all target rather than reject-all.
    while (!s.quit.load(.monotonic)) {
        if (s.connected.load(.monotonic) and
            s.job_epoch.load(.acquire) > 0) break;
        sleepMs(50);
    }

    outer: while (!s.quit.load(.monotonic)) {
        const snap = s.snapshotJob(&jbuf);
        @memcpy(&blob0, &snap.blob);
        @memcpy(&blob1, &snap.blob);
        const epoch = snap.epoch;
        difficulty.computeTarget(snap.difficulty, &target);
        var nonce: u32 = @as(u32, @intCast(tid & 0xff)) << 24;
        blob0[THREAD_ID_OFFSET] = @truncate(tid);
        blob1[THREAD_ID_OFFSET] = @truncate(tid);

        while (true) {
            if (s.quit.load(.monotonic)) break :outer;
            // Stop hashing the instant the connection drops (port of tnn
            // mine_dero.cpp:198 `if (!isConnected) break;`): while disconnected we can
            // neither submit a hit nor get fresh jobs, so the current template is
            // doomed -- bail to the outer gate, which re-waits for `connected` and
            // resumes on the fresh job after reconnect.
            if (!s.connected.load(.monotonic)) break;
            if ((nonce & 127) == 0 and s.job_epoch.load(.acquire) != epoch) break;

            writeNonce(&blob0, nonce +% 1);
            writeNonce(&blob1, nonce +% 2);
            nonce +%= 2;

            pow.hash2(&blob0, &blob1, &out0, &out1, w0, w1) catch continue;

            if (difficulty.checkHash(&out0, &target)) {
                var hex: [BLOB_LEN * 2]u8 = undefined;
                toHex(&blob0, &hex);
                s.stageShare(jbuf[0..snap.jobid_len], &hex, epoch);
            }
            if (difficulty.checkHash(&out1, &target)) {
                var hex: [BLOB_LEN * 2]u8 = undefined;
                toHex(&blob1, &hex);
                s.stageShare(jbuf[0..snap.jobid_len], &hex, epoch);
            }

            local_hashes += 2;
            if ((local_hashes & 63) == 0) {
                _ = s.total_hashes.fetchAdd(64, .monotonic);
                local_hashes = 0;
            }
        }
    }

    if (local_hashes > 0) _ = s.total_hashes.fetchAdd(local_hashes, .monotonic);
}

test "toHex + nonce placement" {
    var b = [_]u8{0} ** BLOB_LEN;
    const nonce: u32 = 0x11223344;
    b[NONCE_OFFSET + 0] = @truncate(nonce >> 24);
    b[NONCE_OFFSET + 1] = @truncate(nonce >> 16);
    b[NONCE_OFFSET + 2] = @truncate(nonce >> 8);
    b[NONCE_OFFSET + 3] = @truncate(nonce);
    try std.testing.expectEqual(@as(u8, 0x11), b[43]);
    try std.testing.expectEqual(@as(u8, 0x44), b[46]);
    var hex: [BLOB_LEN * 2]u8 = undefined;
    toHex(&b, &hex);
    try std.testing.expectEqualStrings("11223344", hex[86..94]);
}
