//! state.zig -- MinerState: all shared mutable state between the network thread and
//! the mining threads. One global instance. Mirrors the C MinerState.
const std = @import("std");

pub const BLOB_LEN = 48;
pub const MAX_JOBID = 128;
pub const SUBMIT_RING = 8; // submit mailbox depth: enough to never drop a found miniblock

const Atomic = std.atomic.Value;

// std.Thread.Mutex was removed in Zig 0.16. Wrap a pthread_mutex_t in a tiny
// helper with the same .lock()/.unlock() surface so the rest of this file
// doesn't have to thread an Io around every critical section.
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// One staged submission (a found miniblock awaiting send).
const SubmitEntry = struct {
    jobid: [MAX_JOBID]u8 = undefined,
    jobid_len: usize = 0,
    blob_hex: [BLOB_LEN * 2]u8 = undefined,
    epoch: u64 = 0,
};

pub const MinerState = struct {
    // ---- job (blob/jobid/height under job_mutex; difficulty/epoch atomic) ----
    job_mutex: Mutex = .{},
    blob: [BLOB_LEN]u8 = [_]u8{0} ** BLOB_LEN,
    jobid_buf: [MAX_JOBID]u8 = undefined,
    jobid_len: usize = 0,
    height: Atomic(i64) = Atomic(i64).init(0),
    difficulty: Atomic(u64) = Atomic(u64).init(0),
    job_epoch: Atomic(u64) = Atomic(u64).init(0),

    connected: Atomic(bool) = Atomic(bool).init(false),
    quit: Atomic(bool) = Atomic(bool).init(false),

    // ---- submit mailbox: small FIFO ring so concurrent hits are never dropped ----
    // The reference C spin-waits to deposit a single in-flight share; an 8-entry ring
    // gives the same "never drop a found miniblock" without blocking the miner thread.
    submit_mutex: Mutex = .{},
    submit_ready: Atomic(bool) = Atomic(bool).init(false), // ring non-empty (lock-free hint)
    submit_ring: [SUBMIT_RING]SubmitEntry = undefined,
    submit_head: usize = 0, // index of next entry to pop
    submit_count: usize = 0, // entries currently queued

    // ---- counters ----
    total_hashes: Atomic(i64) = Atomic(i64).init(0),
    accepted: Atomic(i64) = Atomic(i64).init(0),
    rejected: Atomic(i64) = Atomic(i64).init(0),
    blocks: Atomic(i64) = Atomic(i64).init(0),
    submitted: Atomic(i64) = Atomic(i64).init(0),
    stale_drops: Atomic(i64) = Atomic(i64).init(0),
    submit_drops: Atomic(i64) = Atomic(i64).init(0), // found a share but the ring was full

    // ---- config (set once at startup, read-only after) ----
    // Compiled-in backstop defaults: a user who forgets -w/-d (and has no config.json)
    // still mines to the community pool. config.json and CLI flags override these.
    host: []const u8 = "community-pools.mysrv.cloud",
    port: u16 = 10300,
    // Transport for the getwork WebSocket: true => TLS (wss://, the default pool);
    // false => plaintext (ws://, a local derod daemon). Set from the -d/config scheme.
    tls: bool = true,
    wallet: []const u8 = "dero1qyvuemd6z0uzsx5ufc99f0jhyzvvpysmrd2t3526ht7a9dfh7jve2qqt0vu5y",
    nthreads: usize = 0,

    pub const JobSnapshot = struct { epoch: u64, difficulty: u64, blob: [BLOB_LEN]u8, jobid_len: usize };

    /// Called by the network layer when a job arrives. Returns true if work changed.
    pub fn setJob(self: *MinerState, blob: *const [BLOB_LEN]u8, jobid: []const u8, height: i64, difficulty: u64) bool {
        self.job_mutex.lock();
        defer self.job_mutex.unlock();

        const jid = jobid[0..@min(jobid.len, MAX_JOBID)];
        const changed = !std.mem.eql(u8, &self.blob, blob) or
            self.height.load(.monotonic) != height or
            self.difficulty.load(.monotonic) != difficulty or
            !std.mem.eql(u8, self.jobid_buf[0..self.jobid_len], jid);

        @memcpy(&self.blob, blob);
        @memcpy(self.jobid_buf[0..jid.len], jid);
        self.jobid_len = jid.len;
        self.height.store(height, .monotonic);
        self.difficulty.store(difficulty, .monotonic);
        if (changed) _ = self.job_epoch.fetchAdd(1, .monotonic);
        return changed;
    }

    /// Snapshot the current job into `out_jobid` (must be >= MAX_JOBID).
    pub fn snapshotJob(self: *MinerState, out_jobid: []u8) JobSnapshot {
        self.job_mutex.lock();
        defer self.job_mutex.unlock();
        var snap = JobSnapshot{
            .epoch = self.job_epoch.load(.monotonic),
            .difficulty = self.difficulty.load(.monotonic),
            .blob = self.blob,
            .jobid_len = self.jobid_len,
        };
        @memcpy(out_jobid[0..self.jobid_len], self.jobid_buf[0..self.jobid_len]);
        _ = &snap;
        return snap;
    }

    /// Miner found a candidate; push it onto the submit ring (stale-gated by epoch).
    /// Never overwrites a still-pending share -- a full ring counts a submit_drop
    /// (which should be ~never at solo difficulty).
    pub fn stageShare(self: *MinerState, jobid: []const u8, blob_hex: *const [BLOB_LEN * 2]u8, epoch: u64) void {
        if (self.job_epoch.load(.acquire) != epoch) {
            _ = self.stale_drops.fetchAdd(1, .monotonic);
            return;
        }
        self.submit_mutex.lock();
        defer self.submit_mutex.unlock();
        if (self.job_epoch.load(.acquire) != epoch) {
            _ = self.stale_drops.fetchAdd(1, .monotonic);
            return;
        }
        if (self.submit_count >= SUBMIT_RING) {
            _ = self.submit_drops.fetchAdd(1, .monotonic);
            return;
        }
        const tail = (self.submit_head + self.submit_count) % SUBMIT_RING;
        const e = &self.submit_ring[tail];
        const jid = jobid[0..@min(jobid.len, MAX_JOBID)];
        @memcpy(e.jobid[0..jid.len], jid);
        e.jobid_len = jid.len;
        @memcpy(&e.blob_hex, blob_hex);
        e.epoch = epoch;
        self.submit_count += 1;
        self.submit_ready.store(true, .release);
    }

    pub const StagedShare = struct { jobid_len: usize, epoch: u64 };

    /// Network side: pop the next non-stale staged share into caller buffers. Skips and
    /// counts stale entries. Returns null when the ring holds no fresh share. Call in a
    /// loop to drain a backlog: `while (takeStagedShare(...)) |s| send(s)`.
    pub fn takeStagedShare(self: *MinerState, out_jobid: []u8, out_blob_hex: []u8) ?StagedShare {
        if (!self.submit_ready.load(.acquire)) return null;
        self.submit_mutex.lock();
        defer self.submit_mutex.unlock();
        const cur_epoch = self.job_epoch.load(.acquire);
        while (self.submit_count > 0) {
            const e = &self.submit_ring[self.submit_head];
            self.submit_head = (self.submit_head + 1) % SUBMIT_RING;
            self.submit_count -= 1;
            if (self.submit_count == 0) self.submit_ready.store(false, .release);
            if (e.epoch != cur_epoch) {
                _ = self.stale_drops.fetchAdd(1, .monotonic);
                continue; // stale -> skip, try the next entry
            }
            @memcpy(out_jobid[0..e.jobid_len], e.jobid[0..e.jobid_len]);
            @memcpy(out_blob_hex[0 .. BLOB_LEN * 2], &e.blob_hex);
            return .{ .jobid_len = e.jobid_len, .epoch = e.epoch };
        }
        self.submit_ready.store(false, .release);
        return null;
    }
};

test "setJob detects change and bumps epoch; stage/take roundtrip" {
    var s = MinerState{};
    var blob = [_]u8{0} ** BLOB_LEN;
    blob[0] = 0xAB;
    try std.testing.expect(s.setJob(&blob, "job1", 100, 1000));
    try std.testing.expectEqual(@as(u64, 1), s.job_epoch.load(.monotonic));
    // same job -> no change
    try std.testing.expect(!s.setJob(&blob, "job1", 100, 1000));
    try std.testing.expectEqual(@as(u64, 1), s.job_epoch.load(.monotonic));

    var hex = [_]u8{'a'} ** (BLOB_LEN * 2);
    s.stageShare("job1", &hex, 1);
    var jbuf: [MAX_JOBID]u8 = undefined;
    var hbuf: [BLOB_LEN * 2]u8 = undefined;
    const got = s.takeStagedShare(&jbuf, &hbuf).?;
    try std.testing.expectEqualStrings("job1", jbuf[0..got.jobid_len]);
    try std.testing.expectEqualSlices(u8, &hex, &hbuf);
    // mailbox now empty
    try std.testing.expect(s.takeStagedShare(&jbuf, &hbuf) == null);
}

test "submit ring: FIFO order, none lost, ring-full and stale handling" {
    var s = MinerState{};
    var blob = [_]u8{0} ** BLOB_LEN;
    blob[0] = 0xCD;
    try std.testing.expect(s.setJob(&blob, "j", 1, 1000)); // epoch 1
    var jbuf: [MAX_JOBID]u8 = undefined;
    var hbuf: [BLOB_LEN * 2]u8 = undefined;

    // Stage 3 distinct shares at epoch 1; draining must return them in FIFO order.
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        var hex = [_]u8{0} ** (BLOB_LEN * 2);
        @memset(&hex, 'A' + i);
        s.stageShare("j", &hex, 1);
    }
    i = 0;
    while (i < 3) : (i += 1) {
        _ = s.takeStagedShare(&jbuf, &hbuf) orelse return error.MissingShare;
        for (hbuf) |b| try std.testing.expectEqual(@as(u8, 'A' + i), b);
    }
    try std.testing.expect(s.takeStagedShare(&jbuf, &hbuf) == null);

    // Ring-full: SUBMIT_RING entries fit; the next is dropped and counted.
    i = 0;
    while (i < SUBMIT_RING + 1) : (i += 1) {
        var hex = [_]u8{'a'} ** (BLOB_LEN * 2);
        s.stageShare("j", &hex, 1);
    }
    try std.testing.expectEqual(@as(i64, 1), s.submit_drops.load(.monotonic));
    i = 0;
    while (i < SUBMIT_RING) : (i += 1) try std.testing.expect(s.takeStagedShare(&jbuf, &hbuf) != null);
    try std.testing.expect(s.takeStagedShare(&jbuf, &hbuf) == null);

    // Stale: staged at epoch 1, then the job advances -> taken as stale (null), counted.
    var hexz = [_]u8{'z'} ** (BLOB_LEN * 2);
    s.stageShare("j", &hexz, 1);
    var blob2 = [_]u8{0} ** BLOB_LEN;
    blob2[0] = 0xEE;
    try std.testing.expect(s.setJob(&blob2, "j2", 2, 1000)); // epoch -> 2
    try std.testing.expect(s.takeStagedShare(&jbuf, &hbuf) == null);
    try std.testing.expect(s.stale_drops.load(.monotonic) >= 1);
}
