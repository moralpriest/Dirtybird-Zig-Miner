//! net.zig -- DERO "getwork" client over a TLS WebSocket (Zig 0.14.1).
//!
//! Port of the upstream C `network.cpp`. Transport:
//!   TCP -> TLS handshake (std.crypto.tls.Client, verification DISABLED, mirroring
//!   the C's SSL_VERIFY_NONE) -> HTTP/1.1 Upgrade to WebSocket at `/ws/{wallet}`
//!   -> receive jobs as JSON text frames, submit shares as JSON text frames.
//!
//! ## Read-timeout note (see docs/net-findings.md)
//! `std.Io.net.Stream.read` uses `ReadFile`, which ignores `SO_RCVTIMEO`, and even a
//! Winsock `recv` did not honor it on the socket Zig hands back. So this client
//! hands `tls.Client` a `SelectStream` wrapper whose read waits for readability
//! (independent of `SO_RCVTIMEO`) and then `recv`s. An idle read returns
//! `error.WouldBlock`, exactly the recoverable "no data yet" the C's 50ms
//! `SO_RCVTIMEO` produced. This keeps the faithful single-thread design: one loop
//! interleaves recv + share submit; teardown is `close` on that thread.
//!
//! ## Cross-platform raw-socket layer
//! The TLS/WebSocket/getwork layers above are already portable; only the raw
//! socket layer differs. It is split on `builtin.os.tag`:
//!   - Windows: Winsock (`ws2_32`) with `select()` for read readiness. PRESERVED
//!     byte-for-byte -- the comment above explains why `select()` (not recv's own
//!     timeout) gates the read here.
//!   - POSIX (Linux/Android/macOS): `std.posix` with `poll(POLLIN)` for read
//!     readiness. The std.posix wrappers map errno into Zig error sets, which we
//!     fold into the SAME `SockError` set so the callers above are unchanged.
//!
//! ## Public API
//! ```
//! const job: Job = ...;                 // 48-byte blob + jobid + height + diff + counters
//! const cfg = Config{ .host = ..., .port = ..., .wallet = ... };
//! const hooks = Hooks{ .ctx = ..., .on_job = ..., .poll_share = ...,
//!                      .set_connected = ..., .should_quit = ... };
//! net.run(allocator, cfg, hooks);       // blocking connect+reconnect loop
//! ```
//! Pure, testable building blocks (used by `run`, exercised by tests):
//!   base64Encode, wsEncodeFrame, WsFrameParser, parseJob, buildSubmit.

const std = @import("std");
const builtin = @import("builtin");
const tls = std.crypto.tls;
const is_windows = builtin.os.tag == .windows;

// SIGPIPE suppression for POSIX `send`: Linux has MSG.NOSIGNAL; macOS/BSD lack it
// (it's `void` there), so on non-Linux POSIX we send with no flag and instead
// ignore SIGPIPE process-wide at connect (see connectAndUpgrade).
const posix_send_flags: u32 = if (builtin.os.tag == .linux) std.posix.MSG.NOSIGNAL else 0;
// Winsock declarations are comptime-available on every target, but every USE of
// `ws2` below lives inside an `if (is_windows)` branch so the POSIX build (which
// prunes that dead branch) never tries to resolve a Windows-only call.
const ws2 = std.os.windows.ws2_32;

// std.time.milliTimestamp / std.time.sleep were removed in Zig 0.16. We use libc
// clock_gettime / nanosleep (libc is already linked for the SA objects).
fn nowMsMonotonic() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    const req = std.posix.timespec{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .nsec = @intCast(@rem(ms, 1000) * std.time.ns_per_ms),
    };
    _ = std.posix.system.nanosleep(&req, null);
}

// ===========================================================================
// Public types
// ===========================================================================

/// Size of a DERO miniblock / block-hashing blob, in bytes (96 hex chars).
pub const BLOB_SIZE = 48;

pub const Job = struct {
    blob: [BLOB_SIZE]u8 = [_]u8{0} ** BLOB_SIZE,
    jobid_buf: [128]u8 = undefined,
    jobid_len: usize = 0,
    height: i64 = 0,
    difficulty: u64 = 0,
    miniblocks: i64 = 0,
    blocks: i64 = 0,
    rejected: i64 = 0,

    pub fn jobid(self: *const Job) []const u8 {
        return self.jobid_buf[0..self.jobid_len];
    }
    fn setJobid(self: *Job, s: []const u8) void {
        const n = @min(s.len, self.jobid_buf.len);
        @memcpy(self.jobid_buf[0..n], s[0..n]);
        self.jobid_len = n;
    }
};

pub const Config = struct {
    host: []const u8,
    port: u16,
    wallet: []const u8,
    /// true => TLS (wss://, pools); false => plaintext (ws://, a local derod daemon).
    tls: bool,
};

pub const Share = struct {
    jobid: []const u8,
    mbl_blob_hex: []const u8,
};

/// Caller-provided integration hooks (the miner supplies these).
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Called whenever a new/changed, well-formed job arrives.
    on_job: *const fn (ctx: *anyopaque, job: *const Job) void,
    /// Called frequently (every read timeout and after each frame). Return a
    /// share to submit, or null. The returned slices must remain valid until the
    /// next call to poll_share (point them at caller-owned buffers).
    poll_share: *const fn (ctx: *anyopaque) ?Share,
    /// Called on connect (true) and disconnect (false) so the miner can gate hashing.
    set_connected: *const fn (ctx: *anyopaque, connected: bool) void,
    /// Emit a timestamped INFO/WARN/ERROR log line (mirrors the C's network.cpp log_line:
    /// "Connecting (...)" / "Connected (...) (N ms)"). The miner supplies the console sink;
    /// net.zig only formats the message text, so this file stays free of time/platform code.
    log: *const fn (ctx: *anyopaque, level: []const u8, msg: []const u8) void,
    /// Return true to stop the run loop (shutdown).
    should_quit: *const fn (ctx: *anyopaque) bool,
};

// ===========================================================================
// base64 (for Sec-WebSocket-Key) -- matches the C's std b64 alphabet
// ===========================================================================

const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding. `out` must be at least `((data.len+2)/3)*4`.
/// Returns the encoded slice.
pub fn base64Encode(out: []u8, data: []const u8) []const u8 {
    var oi: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 3) {
        var v: u32 = @as(u32, data[i]) << 16;
        if (i + 1 < data.len) v |= @as(u32, data[i + 1]) << 8;
        if (i + 2 < data.len) v |= @as(u32, data[i + 2]);
        out[oi] = b64_alphabet[(v >> 18) & 0x3f];
        out[oi + 1] = b64_alphabet[(v >> 12) & 0x3f];
        out[oi + 2] = if (i + 1 < data.len) b64_alphabet[(v >> 6) & 0x3f] else '=';
        out[oi + 3] = if (i + 2 < data.len) b64_alphabet[v & 0x3f] else '=';
        oi += 4;
    }
    return out[0..oi];
}

// ===========================================================================
// WebSocket framing (RFC 6455)
// ===========================================================================

pub const Opcode = struct {
    pub const continuation: u8 = 0x0;
    pub const text: u8 = 0x1;
    pub const binary: u8 = 0x2;
    pub const close: u8 = 0x8;
    pub const ping: u8 = 0x9;
    pub const pong: u8 = 0xA;
};

/// Encode a client->server frame (always masked, FIN set) into `out`.
/// `mask` is the 4 random masking bytes. Returns the encoded slice.
/// `out` must hold at least `payload.len + 14`.
pub fn wsEncodeFrame(out: []u8, opcode: u8, payload: []const u8, mask: [4]u8) []const u8 {
    var hdr: usize = 0;
    out[0] = 0x80 | (opcode & 0x0f); // FIN + opcode
    const len = payload.len;
    if (len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(len)); // MASK bit + 7-bit len
        hdr = 2;
    } else if (len < 65536) {
        out[1] = 0x80 | 126;
        out[2] = @intCast((len >> 8) & 0xff);
        out[3] = @intCast(len & 0xff);
        hdr = 4;
    } else {
        out[1] = 0x80 | 127;
        const l: u64 = len;
        var i: usize = 0;
        while (i < 8) : (i += 1) out[2 + i] = @intCast((l >> @intCast(56 - 8 * i)) & 0xff);
        hdr = 10;
    }
    @memcpy(out[hdr .. hdr + 4], &mask);
    hdr += 4;
    var i: usize = 0;
    while (i < len) : (i += 1) out[hdr + i] = payload[i] ^ mask[i & 3];
    return out[0 .. hdr + len];
}

/// Result of feeding bytes to the streaming WS frame parser.
pub const FrameResult = union(enum) {
    /// Need more bytes before a full frame is available.
    incomplete,
    /// A complete data/control frame. `payload` points into the parser buffer
    /// and is valid until the next `next()` call.
    frame: struct { opcode: u8, fin: bool, payload: []const u8 },
    /// Protocol error -> caller must reconnect.
    protocol_error,
};

/// Streaming, allocation-light WebSocket frame parser for SERVER->client frames
/// (unmasked). Bytes are appended via `push`; `next` extracts one frame at a
/// time. Control frames > 125 bytes and the 126/127-encoded control frames are
/// rejected (RFC 6455 5.5). Max payload guard mirrors the C's 1 MiB cap.
pub const WsFrameParser = struct {
    buf: std.ArrayList(u8), // raw received bytes not yet consumed
    payload: std.ArrayList(u8), // owned copy of the most recent frame's payload
    gpa: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WsFrameParser {
        return .{
            .buf = .empty,
            .payload = .empty,
            .gpa = allocator,
        };
    }
    pub fn deinit(self: *WsFrameParser) void {
        self.buf.deinit(self.gpa);
        self.payload.deinit(self.gpa);
    }

    const max_payload: usize = 1024 * 1024;

    /// Append received bytes to the parser buffer.
    pub fn push(self: *WsFrameParser, bytes: []const u8) !void {
        try self.buf.appendSlice(self.gpa, bytes);
    }

    /// Try to extract the next complete frame. On `.frame`, the payload slice is
    /// owned by the parser and valid only until the next `next()` call. An
    /// allocation failure while copying the payload surfaces as `.protocol_error`
    /// (which the run loop treats as a reconnect).
    pub fn next(self: *WsFrameParser) FrameResult {
        const data = self.buf.items;
        if (data.len < 2) return .incomplete;

        const fin = (data[0] & 0x80) != 0;
        const opcode = data[0] & 0x0f;
        const masked = (data[1] & 0x80) != 0;
        var plen: u64 = data[1] & 0x7f;
        var off: usize = 2;

        if (plen == 126) {
            if (data.len < 4) return .incomplete;
            plen = (@as(u64, data[2]) << 8) | data[3];
            off = 4;
        } else if (plen == 127) {
            if (data.len < 10) return .incomplete;
            plen = 0;
            var i: usize = 2;
            while (i < 10) : (i += 1) plen = (plen << 8) | data[i];
            off = 10;
        }

        if (plen > max_payload) return .protocol_error;
        // RFC 6455 5.5: control frames carry <=125-byte payloads, not fragmented.
        // plen is fully decoded, so this also rejects a control frame that
        // illegally used the 126/127 extended-length encoding.
        if (opcode >= 0x8 and plen > 125) return .protocol_error;

        // Server frames must be unmasked, but tolerate a mask field if present.
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            if (data.len < off + 4) return .incomplete;
            @memcpy(&mask, data[off .. off + 4]);
            off += 4;
        }

        const total = off + @as(usize, @intCast(plen));
        if (data.len < total) return .incomplete;

        // Copy the payload into our owned buffer before compacting `buf` (the
        // compaction below overwrites the front of `buf`, which can overlap the
        // payload region when remaining > off).
        self.payload.clearRetainingCapacity();
        self.payload.appendSlice(self.gpa, data[off..total]) catch return .protocol_error;
        if (masked) {
            var i: usize = 0;
            while (i < self.payload.items.len) : (i += 1) self.payload.items[i] ^= mask[i & 3];
        }

        // Consume this frame from the buffer (compact remaining bytes to front).
        const remaining = data.len - total;
        std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[total..]);
        self.buf.shrinkRetainingCapacity(remaining);

        return .{ .frame = .{ .opcode = opcode, .fin = fin, .payload = self.payload.items } };
    }
};

// ===========================================================================
// JSON field extraction (tolerant scanner, matches the C's substring approach)
// ===========================================================================

/// Extract a string value for `"key":"value"` (no nested objects/escapes), like
/// the C's json_str. Returns null on miss.
pub fn jsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [128]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, pat) orelse return null;
    const vstart = start + pat.len;
    const rest = json[vstart..];
    const qend = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..qend];
}

/// Extract a bare int value for `"key":12345`, like the C's json_int.
/// Returns 0 on miss or if the value is a string. Tolerates leading whitespace.
pub fn jsonInt(json: []const u8, key: []const u8) i64 {
    var pat_buf: [128]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return 0;
    const start = std.mem.indexOf(u8, json, pat) orelse return 0;
    var p = start + pat.len;
    while (p < json.len and (json[p] == ' ' or json[p] == '\t')) p += 1;
    if (p >= json.len or json[p] == '"') return 0; // string, not int
    // Parse optional sign + digits.
    var end = p;
    if (end < json.len and (json[end] == '-' or json[end] == '+')) end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == p) return 0;
    return std.fmt.parseInt(i64, json[p..end], 10) catch 0;
}

pub const ParseError = error{ MissingBlob, MissingJobid, BadBlobLen, BadBlobHex };

/// Parse a DERO getwork job JSON into a Job. Mirrors the C's handle_job guards:
/// blockhashing_blob and jobid required; blob must be exactly 96 hex chars
/// (48 bytes). Optional counters/lasterror are read if present. `lasterror`, if
/// non-empty, is returned via `out_lasterror` (a slice into `json`) for logging.
pub fn parseJob(json: []const u8, out_lasterror: ?*?[]const u8) ParseError!Job {
    if (out_lasterror) |slot| {
        slot.* = if (jsonStr(json, "lasterror")) |e| (if (e.len > 0) e else null) else null;
    }
    const blob_hex = jsonStr(json, "blockhashing_blob") orelse return error.MissingBlob;
    const jid = jsonStr(json, "jobid") orelse return error.MissingJobid;
    if (jid.len == 0) return error.MissingJobid; // C's handle_job rejects empty jobid
    if (blob_hex.len != BLOB_SIZE * 2) return error.BadBlobLen;

    var job = Job{};
    _ = std.fmt.hexToBytes(&job.blob, blob_hex) catch return error.BadBlobHex;
    job.setJobid(jid);
    job.height = jsonInt(json, "height");
    // A negative / out-of-range difficulty (only reachable from a malformed or
    // hostile daemon) sanitizes to 0 (degenerate) rather than @bitCasting into a
    // huge u64 that would later crash the signed target math.
    job.difficulty = std.math.cast(u64, jsonInt(json, "difficultyuint64")) orelse 0;
    job.miniblocks = jsonInt(json, "miniblocks");
    job.blocks = jsonInt(json, "blocks");
    job.rejected = jsonInt(json, "rejected");
    return job;
}

/// Build the share submission JSON `{"jobid":"<jid>","mbl_blob":"<hex>"}` into
/// `out`. Returns the slice. Mirrors the C's submit_share snprintf.
pub fn buildSubmit(out: []u8, share: Share) ![]const u8 {
    return std.fmt.bufPrint(out, "{{\"jobid\":\"{s}\",\"mbl_blob\":\"{s}\"}}", .{ share.jobid, share.mbl_blob_hex });
}

// ===========================================================================
// SelectStream: tls.Client stream wrapper with select()-based read timeout.
// ===========================================================================

const SockError = error{ WouldBlock, Closed, ConnectionReset, Unexpected };

/// Implements the duck-typed std.crypto.tls.Client stream interface using a
/// per-OS raw socket layer (Winsock on Windows, std.posix elsewhere) with a
/// readiness wait (`select`/`poll`) for the read timeout. The handle type is
/// `std.posix.socket_t`, which IS `ws2.SOCKET` on Windows, so the Windows path
/// is unchanged and `std.Io.net.Stream.handle` plugs straight in on both.
const SelectStream = struct {
    handle: std.posix.socket_t,
    timeout_ms: u32,

    pub const ReadError = SockError;
    pub const WriteError = SockError;

    fn waitReadable(s: SelectStream) SockError!void {
        if (is_windows) {
            var rset = ws2.fd_set{ .fd_count = 1, .fd_array = undefined };
            rset.fd_array[0] = s.handle;
            var tv = ws2.timeval{
                .sec = @intCast(s.timeout_ms / 1000),
                .usec = @intCast((s.timeout_ms % 1000) * 1000),
            };
            const sr = ws2.select(0, &rset, null, null, &tv); // nfds ignored on Windows
            if (sr == 0) return error.WouldBlock;
            if (sr == ws2.SOCKET_ERROR) return error.Unexpected;
        } else {
            // POSIX: poll() for read readiness, mirroring the Windows select().
            var fds = [_]std.posix.pollfd{.{ .fd = s.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, @intCast(s.timeout_ms)) catch return error.Unexpected;
            if (ready == 0) return error.WouldBlock; // timeout -> recoverable idle tick
            // POLLERR/HUP/NVAL surface as a dead connection on the recv() below.
        }
    }

    pub fn read(s: SelectStream, buffer: []u8) ReadError!usize {
        try s.waitReadable();
        if (is_windows) {
            const n = ws2.recv(s.handle, buffer.ptr, @intCast(buffer.len), 0);
            if (n == ws2.SOCKET_ERROR) {
                return switch (ws2.WSAGetLastError()) {
                    .WSAETIMEDOUT, .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAECONNRESET, .WSAECONNABORTED, .WSAENOTCONN, .WSAESHUTDOWN => error.ConnectionReset,
                    else => error.Unexpected,
                };
            }
            return @intCast(n);
        } else {
            // Zig 0.16 removed std.posix.recv; use raw Linux recvfrom (no address needed).
            const rc = std.os.linux.recvfrom(s.handle, buffer.ptr, buffer.len, 0, null, null);
            const signed: isize = @bitCast(rc);
            if (signed < 0) {
                const err: std.os.linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
                return switch (err) {
                    .AGAIN => error.WouldBlock,
                    .CONNRESET, .TIMEDOUT, .NOTCONN, .CONNREFUSED => error.ConnectionReset,
                    else => error.Unexpected,
                };
            }
            return @intCast(rc);
        }
    }
    pub fn readv(s: SelectStream, iovecs: []std.posix.iovec) ReadError!usize {
        if (iovecs.len == 0) return 0;
        const first = iovecs[0];
        return s.read(first.base[0..first.len]);
    }
    pub fn readAtLeast(s: SelectStream, buffer: []u8, len: usize) ReadError!usize {
        std.debug.assert(len <= buffer.len);
        var index: usize = 0;
        while (index < len) {
            const amt = try s.read(buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
        return index;
    }
    pub fn write(s: SelectStream, buffer: []const u8) WriteError!usize {
        if (is_windows) {
            const n = ws2.send(s.handle, buffer.ptr, @intCast(buffer.len), 0);
            if (n == ws2.SOCKET_ERROR) {
                return switch (ws2.WSAGetLastError()) {
                    // A send timeout (SO_SNDTIMEO) or backpressure on a wedged peer is
                    // treated as a dead connection -> reconnect, not a fatal Unexpected.
                    .WSAETIMEDOUT, .WSAEWOULDBLOCK, .WSAECONNRESET, .WSAECONNABORTED, .WSAENOTCONN, .WSAESHUTDOWN => error.ConnectionReset,
                    else => error.Unexpected,
                };
            }
            return @intCast(n);
        } else {
            // Zig 0.16 removed std.posix.send; use raw Linux sendto with MSG.NOSIGNAL.
            const flags = posix_send_flags;
            const rc = std.os.linux.sendto(s.handle, buffer.ptr, buffer.len, flags, null, 0);
            const signed: isize = @bitCast(rc);
            if (signed < 0) {
                const err: std.os.linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
                return switch (err) {
                    .AGAIN, // EAGAIN/EWOULDBLOCK (send timeout / backpressure)
                    .PIPE, // EPIPE (peer closed; MSG.NOSIGNAL suppresses SIGPIPE)
                    .CONNRESET => error.ConnectionReset,
                    else => error.Unexpected,
                };
            }
            return @intCast(rc);
        }
    }
    pub fn writev(s: SelectStream, iovecs: []const std.posix.iovec_const) WriteError!usize {
        if (iovecs.len == 0) return 0;
        const first = iovecs[0];
        return s.write(first.base[0..first.len]);
    }
    pub fn writevAll(s: SelectStream, iovecs: []std.posix.iovec_const) WriteError!void {
        if (iovecs.len == 0) return;
        var i: usize = 0;
        while (true) {
            var amt = try s.writev(iovecs[i..]);
            while (amt >= iovecs[i].len) {
                amt -= iovecs[i].len;
                i += 1;
                if (i >= iovecs.len) return;
            }
            iovecs[i].base += amt;
            iovecs[i].len -= amt;
        }
    }
};

// ===========================================================================
// Connection + run loop
// ===========================================================================

const CONNECT_TIMEOUT_MS: u32 = 10000; // generous read timeout for handshake+upgrade
const MINING_TIMEOUT_MS: u32 = 50; // 50ms read timeout once mining (matches the C)
const MAX_STALL_POLLS: u32 = 200; // 200 * 50ms = 10s mid-frame stall bound (matches the C)
const CONNECT_DEADLINE_MS: i64 = 20000; // wall-clock ceiling on the whole connect+upgrade phase
const MIN_UPTIME_MS: i64 = 10000; // session must last this long to earn a fast reconnect
const JOB_INACTIVITY_MS: i64 = 60000; // reconnect if no inbound bytes arrive for this long (the C's 60s read timeout)

/// True when a link has been silent past the inactivity threshold. Pure -> unit-testable.
fn shouldReconnect(now_ms: i64, last_progress_ms: i64, threshold_ms: i64) bool {
    return now_ms - last_progress_ms >= threshold_ms;
}

test "shouldReconnect inactivity predicate" {
    try std.testing.expect(!shouldReconnect(1000, 1000, 60000)); // no time elapsed
    try std.testing.expect(!shouldReconnect(60999, 1000, 60000)); // 59.999s < 60s
    try std.testing.expect(shouldReconnect(61000, 1000, 60000)); // exactly 60s -> reconnect
    try std.testing.expect(shouldReconnect(200000, 1000, 60000)); // well past
}
const BACKOFF_START_MS: i64 = 1000;
const BACKOFF_MAX_MS: i64 = 30000;

const Conn = struct {
    netstream: std.Io.net.Stream, // owns the socket handle
    client: ?tls.Client, // null => plaintext ws:// (local daemon); set => TLS wss:// (pool)
    timeout_ms: u32,

    // --- Io.Reader / Io.Writer adapters for the TLS layer (0.16) ---
    // The TLS Client in 0.16 takes (*Io.Reader, *Io.Writer) for the raw network
    // transport instead of a stream object. These VTable adapters bridge
    // SelectStream's poll+recv/send into the Io abstraction.
    io_r_buf: [tls.Client.min_buffer_len]u8 = undefined,
    io_w_buf: [tls.Client.min_buffer_len]u8 = undefined,
    io_r: std.Io.Reader = undefined,
    io_w: std.Io.Writer = undefined,

    fn stream(self: *Conn) SelectStream {
        return .{ .handle = self.netstream.socket.handle, .timeout_ms = self.timeout_ms };
    }

    /// Initialise the Io.Reader / Io.Writer VTable adapters and perform the TLS handshake.
    /// Must be called *after* the TCP socket is connected (netstream is live).
    fn initTls(self: *Conn) !void {
        self.io_r = .{
            .vtable = &.{
                .stream = netReaderStream,
            },
            .buffer = &self.io_r_buf,
            .seek = 0,
            .end = 0,
        };
        // Writer is unbuffered (buffer is empty) so drain is called on every write.
        self.io_w = .{
            .vtable = &.{
                .drain = netWriterDrain,
            },
            .buffer = &self.io_w_buf,
            .end = 0,
        };
        // TLS Client options: need write_buffer, read_buffer, entropy, realtime_now.
        var entropy_buf: [tls.Client.Options.entropy_len]u8 = undefined;
        // Fill entropy using the Linux getrandom syscall (std.crypto.random removed in 0.16).
        {
            var filled: usize = 0;
            while (filled < entropy_buf.len) {
                const rc = std.os.linux.getrandom(entropy_buf[filled..].ptr, entropy_buf.len - filled, 0);
                const signed: isize = @bitCast(rc);
                if (signed < 0) return error.Unexpected;
                filled += @intCast(signed);
            }
        }
        // Compute wall-clock realtime for certificate time validation.
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts);
        self.client = try tls.Client.init(&self.io_r, &self.io_w, .{
            .host = .no_verification,
            .ca = .no_verification,
            .write_buffer = &self.io_w_buf,
            .read_buffer = &self.io_r_buf,
            .entropy = &entropy_buf,
            .realtime_now = .{ .nanoseconds = @as(i96, ts.sec) * std.time.ns_per_s + @as(i96, ts.nsec) },
        });
    }

    /// Io.Reader VTable `stream` function: read encrypted bytes from the network
    /// socket into the Reader's internal buffer (or write them to `w`).
    fn netReaderStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        const self: *Conn = @alignCast(@fieldParentPtr("io_r", r));
        const s = self.stream();
        // Read into the Reader's internal buffer (past end).
        const available = limit.minInt(r.buffer.len - r.end);
        if (available == 0) return 0;
        const n = s.read(r.buffer[r.end .. r.end + available]) catch |e| switch (e) {
            error.WouldBlock => return 0,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.EndOfStream;
        r.end += n;
        return n;
    }

    /// Io.Writer VTable `drain` function: send encrypted bytes over the network socket.
    fn netWriterDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Conn = @alignCast(@fieldParentPtr("io_w", w));
        const s = self.stream();
        var total: usize = 0;
        for (data) |d| {
            var i: usize = 0;
            while (i < d.len) {
                const n = s.write(d[i..]) catch return error.WriteFailed;
                if (n == 0) return if (total > 0) total else error.WriteFailed;
                i += n;
                total += n;
            }
        }
        _ = splat;
        return total;
    }

    // Unified app I/O so the upgrade handshake, frame reads, and share writes are
    // transport-agnostic: TLS when a client is present, else the raw socket.
    fn read(self: *Conn, buffer: []u8) !usize {
        if (self.client) |*c| {
            // TLS: read decrypted data from the Client's application reader.
            return c.reader.readSliceShort(buffer);
        }
        return self.stream().read(buffer);
    }
    fn writeAll(self: *Conn, bytes: []const u8) !void {
        if (self.client) |*c| {
            // TLS: write plaintext through the Client's application writer.
            try c.writer.writeAll(bytes);
            return;
        }
        const s = self.stream();
        var off: usize = 0;
        while (off < bytes.len) off += try s.write(bytes[off..]);
    }
    fn close(self: *Conn) void {
        // Close the socket fd directly — std.Io.net.Stream.close requires an Io
        // handle that we don't have in this minimal adapter.
        _ = std.os.linux.close(self.netstream.socket.handle);
    }
};

/// Resolve (IPv4, like the C's AF_INET), TCP connect, TLS handshake (no verify),
/// and HTTP WebSocket upgrade. On success returns a connected Conn plus any
/// bytes that arrived past the `\r\n\r\n` (a coalesced first frame; seed the
/// parser with them). Caller owns the returned Conn and must `close` it.
fn connectAndUpgrade(
    allocator: std.mem.Allocator,
    cfg: Config,
    hooks: Hooks,
    leftover_out: *std.ArrayList(u8),
) !Conn {
    const connect_start = nowMsMonotonic();
    var logbuf: [256]u8 = undefined;
    hooks.log(hooks.ctx, "INFO", std.fmt.bufPrint(&logbuf, "Connecting ({s}:{d})", .{ cfg.host, cfg.port }) catch "Connecting");

    // ---- DNS resolve (IPv4 only, via libc getaddrinfo; std.Io.net.getAddressList was removed in 0.16) ----
    var addr_in: std.posix.sockaddr.in = undefined;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.posix.AF.INET;
    hints.socktype = std.posix.SOCK.STREAM;
    var res_ptr: ?*std.c.addrinfo = null;
    // libc getaddrinfo expects a NUL-terminated C string; copy cfg.host into a
    // sentinel-terminated buffer.
    var c_host: [256:0]u8 = undefined;
    const host_len = @min(cfg.host.len, c_host.len);
    @memcpy(c_host[0..host_len], cfg.host[0..host_len]);
    c_host[host_len] = 0;
    const host_c: [*:0]const u8 = &c_host;
    const rc = std.c.getaddrinfo(host_c, null, &hints, &res_ptr);
    if (@intFromEnum(rc) != 0) return error.DnsFailure;
    const first_opt = res_ptr orelse return error.NoIPv4Address;
    defer std.c.freeaddrinfo(first_opt);
    const first_addr = first_opt.addr orelse return error.NoIPv4Address;
    if (first_addr.family != std.posix.AF.INET) return error.NoIPv4Address;
    addr_in = @as(*const std.posix.sockaddr.in, @ptrCast(@alignCast(first_addr))).*;
    addr_in.port = std.mem.nativeToBig(u16, cfg.port);

    // ---- TCP connect ----
    // Windows: not yet ported to 0.16; builds on this host are Linux-only.
    // POSIX: socket(AF.INET, SOCK.STREAM) + connect to the resolved IPv4, then wrap
    // the fd in a std.Io.net.Stream so Conn/close()/stream()/setTcpNoDelay are unchanged.
    if (is_windows) return error.UnsupportedPlatform;
    const netstream = blk: {
        const sock_fd = std.c.socket(@intCast(std.posix.AF.INET), @intCast(std.posix.SOCK.STREAM), 0);
        if (sock_fd < 0) return error.SocketFailed;
        const fd: std.posix.fd_t = @intCast(sock_fd);
        errdefer _ = std.os.linux.close(fd); // free the fd if connect fails (Conn isn't built yet)
        // Ignore SIGPIPE so a write to a dead peer returns EPIPE instead of killing
        // the process. Required on macOS/BSD (no MSG.NOSIGNAL); harmless on Linux.
        std.posix.sigaction(std.posix.SIG.PIPE, &.{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.mem.zeroes(std.posix.system.sigset_t),
            .flags = 0,
        }, null);
        const connect_rc = std.c.connect(fd, @ptrCast(&addr_in), @sizeOf(std.posix.sockaddr.in));
        if (connect_rc != 0) return error.ConnectFailed;
        // Split the sockaddr.in back into net-port/ip-bytes. New Zig drops the
        // sockaddr layer in favour of a flat Ip4Address.{bytes, port}.
        const addr_bytes: [4]u8 = @bitCast(addr_in.addr);
        const sock = std.Io.net.Socket{
            .handle = fd,
            .address = .{ .ip4 = .{ .bytes = addr_bytes, .port = addr_in.port } },
        };
        break :blk std.Io.net.Stream{ .socket = sock };
    };
    var conn = Conn{ .netstream = netstream, .client = null, .timeout_ms = CONNECT_TIMEOUT_MS };
    errdefer conn.close();

    setTcpNoDelay(netstream.socket.handle);
    setSndTimeout(netstream.socket.handle, CONNECT_TIMEOUT_MS);

    // ---- TLS handshake (wss://), verification disabled (mirrors SSL_VERIFY_NONE).
    //      Skipped for plaintext ws:// (a local derod daemon): the client stays null
    //      and Conn.read/writeAll route straight to the raw socket. ----
    if (cfg.tls) {
        try conn.initTls();
    }

    // ---- HTTP upgrade ----
    var keyraw: [16]u8 = undefined;
    _ = std.os.linux.getrandom(&keyraw, keyraw.len, 0);
    var keyb64: [24]u8 = undefined;
    const wskey = base64Encode(&keyb64, &keyraw);

    var req_buf: [768]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /ws/{s} HTTP/1.1\r\n" ++
        "Host: {s}:{d}\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n", .{ cfg.wallet, cfg.host, cfg.port, wskey });
    try conn.writeAll(req);

    // ---- Read HTTP response until \r\n\r\n; keep bytes past it. ----
    var resp: [4096]u8 = undefined;
    var total: usize = 0;
    var header_end: usize = 0;
    while (true) {
        // Honor shutdown mid-handshake, and bound a peer that trickles bytes
        // forever (defeating the per-read timeout) -- both guards the C has.
        if (hooks.should_quit(hooks.ctx)) return error.Shutdown;
        if (nowMsMonotonic() - connect_start >= CONNECT_DEADLINE_MS) return error.UpgradeStalled;
        const n = conn.read(resp[total..]) catch |e| {
            // A timeout during upgrade is treated as a stalled handshake.
            if (e == error.WouldBlock) return error.UpgradeStalled;
            return e;
        };
        if (n == 0) return error.UpgradeClosed;
        total += n;
        if (std.mem.indexOf(u8, resp[0..total], "\r\n\r\n")) |idx| {
            header_end = idx + 4;
            break;
        }
        if (total >= resp.len) return error.UpgradeTooLarge;
    }
    // Require a "101" status (the C checks for the literal " 101 ").
    if (std.mem.indexOf(u8, resp[0..total], " 101 ") == null) return error.UpgradeRejected;

    const elapsed_ms = nowMsMonotonic() - connect_start;
    hooks.log(hooks.ctx, "INFO", std.fmt.bufPrint(&logbuf, "Connected ({s}:{d}) ({d} ms)", .{ cfg.host, cfg.port, elapsed_ms }) catch "Connected");

    // Seed the WS parser with any bytes that coalesced past the header (the C
    // discards these -- a latent bug; we don't).
    if (total > header_end) try leftover_out.appendSlice(allocator, resp[header_end..total]);

    // Switch to the fast mining-loop read timeout now that we're upgraded.
    conn.timeout_ms = MINING_TIMEOUT_MS;
    return conn;
}

fn setTcpNoDelay(handle: std.posix.socket_t) void {
    const on: u32 = 1;
    if (is_windows) {
        // IPPROTO_TCP = 6, TCP_NODELAY = 1.
        _ = ws2.setsockopt(handle, 6, 1, std.mem.asBytes(&on), @sizeOf(u32));
    } else {
        // Best-effort, like the Windows path (a failure here isn't fatal).
        std.posix.setsockopt(handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&on)) catch {};
    }
}

/// Bound a wedged send (the read side is already bounded by select()/poll()). Set
/// once and kept for the connection's life at the generous connect timeout, NOT
/// the 50ms mining timeout (a tiny share/pong send must not spuriously fail under
/// transient backpressure).
///
/// Windows: SOL_SOCKET=0xffff, SO_SNDTIMEO=0x1005 (a u32 milliseconds value).
/// POSIX: no-op. SO_SNDTIMEO there takes a `struct timeval` whose field names and
/// `time_t` width vary across gnu/musl/android, which is needless cross-target
/// friction for a pure backpressure guard -- and the POSIX send-side error mapping
/// already turns a wedged/timed-out send into ConnectionReset (-> reconnect), so
/// the guarantee the timeout existed to provide is preserved without it.
fn setSndTimeout(handle: std.posix.socket_t, ms: u32) void {
    if (is_windows) {
        const val: u32 = ms;
        _ = ws2.setsockopt(handle, 0xffff, 0x1005, std.mem.asBytes(&val), @sizeOf(u32));
    }
    // POSIX: intentional no-op (see doc comment).
}

/// Send a masked WebSocket frame over the connection (TLS or plaintext).
fn sendFrame(conn: *Conn, scratch: []u8, opcode: u8, payload: []const u8) !void {
    var mask: [4]u8 = undefined;
    {
        const rc = std.os.linux.getrandom(&mask, mask.len, 0);
        const signed: isize = @bitCast(rc);
        if (signed < 0) return error.Unexpected;
    }
    const frame = wsEncodeFrame(scratch, opcode, payload, mask);
    try conn.writeAll(frame);
}

/// Blocking connect+reconnect run loop. Runs on a dedicated thread supplied by
/// the miner; returns when `hooks.should_quit` returns true.
pub fn run(allocator: std.mem.Allocator, cfg: Config, hooks: Hooks) void {
    var backoff: i64 = BACKOFF_START_MS;

    while (!hooks.should_quit(hooks.ctx)) {
        var leftover = std.ArrayList(u8).empty;
        defer leftover.deinit(allocator);

        var conn = connectAndUpgrade(allocator, cfg, hooks, &leftover) catch |err| {
            if (err == error.Shutdown or hooks.should_quit(hooks.ctx)) break;
            backoffSleep(hooks, backoff);
            backoff = @min(backoff * 2, BACKOFF_MAX_MS);
            continue;
        };
        // Connected. (Do NOT reset backoff yet -- only a *useful* session earns it.)
        hooks.set_connected(hooks.ctx, true);

        const useful = sessionLoop(allocator, &conn, hooks, leftover.items) catch false;

        conn.close();
        hooks.set_connected(hooks.ctx, false);

        if (hooks.should_quit(hooks.ctx)) break;
        if (useful) backoff = BACKOFF_START_MS;
        backoffSleep(hooks, backoff);
        backoff = @min(backoff * 2, BACKOFF_MAX_MS);
    }
    hooks.set_connected(hooks.ctx, false);
}

/// One connected session: interleave reading frames with submitting shares.
/// Returns true if the session was "useful" (delivered a job or stayed up
/// >= MIN_UPTIME_MS), which gates the fast-reconnect backoff reset. Returns an
/// error / false on a dead connection (caller reconnects).
fn sessionLoop(
    allocator: std.mem.Allocator,
    conn: *Conn,
    hooks: Hooks,
    seed: []const u8,
) !bool {
    var parser = WsFrameParser.init(allocator);
    defer parser.deinit();
    if (seed.len > 0) try parser.push(seed);

    var send_scratch: [2048]u8 = undefined;
    var submit_buf: [512]u8 = undefined;
    var read_buf: [16384]u8 = undefined;

    var last_job = Job{};
    var have_last = false;
    var got_job = false;
    var stall_polls: u32 = 0; // consecutive idle reads while a partial frame is buffered
    const session_start = nowMsMonotonic();
    var last_progress_ms = session_start; // last time inbound bytes arrived (dead-link watchdog)

    while (!hooks.should_quit(hooks.ctx)) {
        // 1) Drain any complete frames already buffered (handles coalesced seed
        //    and multiple frames in one read).
        while (true) {
            switch (parser.next()) {
                .incomplete => break,
                .protocol_error => return got_job, // reconnect
                .frame => |f| {
                    if (try handleFrame(conn, &send_scratch, f, &last_job, &have_last, hooks))
                        got_job = true;
                    if (f.opcode == Opcode.close) return got_job; // reconnect
                },
            }
        }

        // 2) Submit any pending shares -- drain the submit ring so a backlog of
        //    concurrent hits all leave in one pass (each share's slices stay valid
        //    until the next poll_share, and we consume each before the next call).
        while (hooks.poll_share(hooks.ctx)) |share| {
            const msg = buildSubmit(&submit_buf, share) catch "";
            if (msg.len > 0) sendFrame(conn, &send_scratch, Opcode.text, msg) catch return got_job;
        }

        // 3) Read more bytes (blocks up to MINING_TIMEOUT_MS via select()).
        // KNOWN RESIDUAL (low, hostile-peer-only): a peer trickling < 1 full TLS
        // record keeps recv returning bytes, so client.read loops inside
        // readvAtLeast without surfacing WouldBlock; the stall bound below only
        // fires on full-record idleness. Bounded by the peer's pace; a fully
        // silent peer still surfaces WouldBlock and is handled. Fixing fully needs
        // a record-level read loop; deferred as disproportionate.
        const n = conn.read(&read_buf) catch |e| {
            if (e == error.WouldBlock) {
                // Dead-link watchdog: a silently-dropped TCP (no FIN/RST) returns
                // WouldBlock forever. If no inbound bytes (job OR ping) have arrived
                // for JOB_INACTIVITY_MS, treat the link as dead and reconnect. This
                // also bounds the empty-buffer between-jobs idle, which otherwise
                // `continue`s unbounded. (Matches the C's 60s inbound read timeout.)
                if (shouldReconnect(nowMsMonotonic(), last_progress_ms, JOB_INACTIVITY_MS))
                    return got_job;
                // Partial frame buffered but the body never came: a peer that sent a
                // header then went silent must not wedge us on stale work -- bound it
                // like the C's MAX_STALL_POLLS.
                if (parser.buf.items.len > 0) {
                    stall_polls += 1;
                    if (stall_polls >= MAX_STALL_POLLS) return got_job; // header arrived, body never did
                }
                continue;
            }
            return got_job; // dead connection -> reconnect
        };
        if (n == 0) return got_job; // clean EOF -> reconnect
        stall_polls = 0; // made progress
        last_progress_ms = nowMsMonotonic(); // bytes arrived -> link is alive
        try parser.push(read_buf[0..n]);
    }

    // Quit requested mid-session. Report usefulness for symmetry (unused on quit).
    const uptime = nowMsMonotonic() - session_start;
    return got_job or uptime >= MIN_UPTIME_MS;
}

/// Handle one parsed frame. Returns true iff a well-formed, changed job was
/// delivered (so the session counts as useful). Replies to pings with pongs.
fn handleFrame(
    conn: *Conn,
    send_scratch: []u8,
    f: anytype,
    last_job: *Job,
    have_last: *bool,
    hooks: Hooks,
) !bool {
    switch (f.opcode) {
        Opcode.ping => {
            // Echo payload back as a pong.
            sendFrame(conn, send_scratch, Opcode.pong, f.payload) catch return error.SendFailed;
            return false;
        },
        Opcode.pong => return false,
        Opcode.close => return false, // caller handles reconnect
        Opcode.text, Opcode.binary, Opcode.continuation => {
            if (!f.fin) return false; // we don't reassemble fragments (the C bails too)
            var lasterror: ?[]const u8 = null;
            const job = parseJob(f.payload, &lasterror) catch {
                // Malformed/error-only frame: not a useful job.
                return false;
            };
            // Deliver only on change (height/jobid/diff/blob), like the C.
            const changed = !have_last.* or
                !std.mem.eql(u8, job.jobid(), last_job.jobid()) or
                !std.mem.eql(u8, &job.blob, &last_job.blob) or
                job.height != last_job.height or
                job.difficulty != last_job.difficulty;
            last_job.* = job;
            have_last.* = true;
            if (changed) hooks.on_job(hooks.ctx, last_job);
            // Any well-formed job (changed or not) marks the session useful.
            return true;
        },
        else => return false,
    }
}

/// Sleep up to `ms`, in <=250ms slices that re-check should_quit so shutdown
/// during a grown backoff doesn't lag the join (mirrors the C's backoff_sleep).
fn backoffSleep(hooks: Hooks, ms: i64) void {
    const SLICE: i64 = 250;
    var remaining = ms;
    while (remaining > 0 and !hooks.should_quit(hooks.ctx)) {
        const slice = @min(remaining, SLICE);
        sleepMs(@intCast(slice));
        remaining -= slice;
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

// Force semantic analysis of the entire networking core (run, connectAndUpgrade,
// sessionLoop, handleFrame, SelectStream, ...). Zig is lazy: without this, those
// pub/private decls are never analyzed in a `zig test` build because no test
// references them, so compile errors in the socket layer would go unnoticed.
test "compile: analyze all decls" {
    testing.refAllDeclsRecursive(@This());
}

test "base64 encode known inputs" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("", base64Encode(&out, ""));
    try testing.expectEqualStrings("Zg==", base64Encode(&out, "f"));
    try testing.expectEqualStrings("Zm8=", base64Encode(&out, "fo"));
    try testing.expectEqualStrings("Zm9v", base64Encode(&out, "foo"));
    try testing.expectEqualStrings("Zm9vYg==", base64Encode(&out, "foob"));
    try testing.expectEqualStrings("Zm9vYmFy", base64Encode(&out, "foobar"));
    // 16 zero bytes -> what a Sec-WebSocket-Key would look like for all-zero key.
    const zeros = [_]u8{0} ** 16;
    try testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAA==", base64Encode(&out, &zeros));
}

test "ws frame encode (masked) short payload" {
    var out: [64]u8 = undefined;
    const mask = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    const frame = wsEncodeFrame(&out, Opcode.text, "Hi", mask);
    // FIN+text=0x81, MASK+len2=0x82, mask bytes, then 'H'^1, 'i'^2
    try testing.expectEqual(@as(usize, 8), frame.len);
    try testing.expectEqual(@as(u8, 0x81), frame[0]);
    try testing.expectEqual(@as(u8, 0x82), frame[1]);
    try testing.expectEqualSlices(u8, &mask, frame[2..6]);
    try testing.expectEqual(@as(u8, 'H' ^ 0x01), frame[6]);
    try testing.expectEqual(@as(u8, 'i' ^ 0x02), frame[7]);
}

// Build an UNMASKED server frame for parser round-trip tests.
fn makeServerFrame(out: []u8, opcode: u8, payload: []const u8) []const u8 {
    var hdr: usize = 0;
    out[0] = 0x80 | (opcode & 0x0f);
    const len = payload.len;
    if (len < 126) {
        out[1] = @intCast(len);
        hdr = 2;
    } else if (len < 65536) {
        out[1] = 126;
        out[2] = @intCast((len >> 8) & 0xff);
        out[3] = @intCast(len & 0xff);
        hdr = 4;
    } else {
        out[1] = 127;
        const l: u64 = len;
        var i: usize = 0;
        while (i < 8) : (i += 1) out[2 + i] = @intCast((l >> @intCast(56 - 8 * i)) & 0xff);
        hdr = 10;
    }
    @memcpy(out[hdr .. hdr + len], payload);
    return out[0 .. hdr + len];
}

test "ws frame parser round-trip 7-bit, ping, fragmented push" {
    var parser = WsFrameParser.init(testing.allocator);
    defer parser.deinit();

    var fbuf: [256]u8 = undefined;
    const frame = makeServerFrame(&fbuf, Opcode.text, "hello world");

    // Push in two chunks to exercise the streaming path.
    try parser.push(frame[0..3]);
    try testing.expect(parser.next() == .incomplete);
    try parser.push(frame[3..]);
    switch (parser.next()) {
        .frame => |f| {
            try testing.expectEqual(Opcode.text, f.opcode);
            try testing.expect(f.fin);
            try testing.expectEqualStrings("hello world", f.payload);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(parser.next() == .incomplete);

    // Ping frame.
    const ping = makeServerFrame(&fbuf, Opcode.ping, "pong-me");
    try parser.push(ping);
    switch (parser.next()) {
        .frame => |f| {
            try testing.expectEqual(Opcode.ping, f.opcode);
            try testing.expectEqualStrings("pong-me", f.payload);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "ws frame parser 126 (u16) extended length" {
    var parser = WsFrameParser.init(testing.allocator);
    defer parser.deinit();
    const payload = [_]u8{'a'} ** 200; // > 125 -> uses 126 path
    var fbuf: [256]u8 = undefined;
    const frame = makeServerFrame(&fbuf, Opcode.text, &payload);
    try testing.expectEqual(@as(usize, 204), frame.len); // 4 hdr + 200
    try parser.push(frame);
    switch (parser.next()) {
        .frame => |f| {
            try testing.expectEqual(@as(usize, 200), f.payload.len);
            try testing.expectEqualSlices(u8, &payload, f.payload);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "ws frame parser 127 (u64) extended length" {
    var parser = WsFrameParser.init(testing.allocator);
    defer parser.deinit();
    const payload = [_]u8{'z'} ** 70000; // > 65535 -> uses 127 path
    var fbuf: [70016]u8 = undefined;
    const frame = makeServerFrame(&fbuf, Opcode.binary, &payload);
    try testing.expectEqual(@as(usize, 10 + 70000), frame.len);
    try parser.push(frame);
    switch (parser.next()) {
        .frame => |f| {
            try testing.expectEqual(@as(usize, 70000), f.payload.len);
            try testing.expectEqual(@as(u8, 'z'), f.payload[69999]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "ws frame parser rejects oversized control frame" {
    var parser = WsFrameParser.init(testing.allocator);
    defer parser.deinit();
    // A ping (control) frame with a 126-encoded length of 200 is illegal.
    var fbuf: [256]u8 = undefined;
    const payload = [_]u8{0} ** 200;
    const frame = makeServerFrame(&fbuf, Opcode.ping, &payload);
    try parser.push(frame);
    try testing.expect(parser.next() == .protocol_error);
}

test "ws frame parser two frames in one buffer" {
    var parser = WsFrameParser.init(testing.allocator);
    defer parser.deinit();
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const f1 = makeServerFrame(&b1, Opcode.text, "first");
    const f2 = makeServerFrame(&b2, Opcode.text, "second");
    var combined: [128]u8 = undefined;
    @memcpy(combined[0..f1.len], f1);
    @memcpy(combined[f1.len .. f1.len + f2.len], f2);
    try parser.push(combined[0 .. f1.len + f2.len]);

    switch (parser.next()) {
        .frame => |f| try testing.expectEqualStrings("first", f.payload),
        else => return error.TestUnexpectedResult,
    }
    switch (parser.next()) {
        .frame => |f| try testing.expectEqualStrings("second", f.payload),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(parser.next() == .incomplete);
}

test "parseJob on realistic DERO getwork JSON" {
    // 96 hex chars = 48 bytes.
    const blob_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30";
    const json =
        "{\"blocktemplate_jsonrpc\":\"2.0\"," ++
        "\"jobid\":\"686f.0000abcd.deadbeef\"," ++
        "\"blockhashing_blob\":\"" ++ blob_hex ++ "\"," ++
        "\"height\":3456789,\"difficultyuint64\":123456789," ++
        "\"miniblocks\":7,\"blocks\":2,\"rejected\":1,\"lasterror\":\"\"}";

    var lasterror: ?[]const u8 = null;
    const job = try parseJob(json, &lasterror);
    try testing.expect(lasterror == null);
    try testing.expectEqualStrings("686f.0000abcd.deadbeef", job.jobid());
    try testing.expectEqual(@as(i64, 3456789), job.height);
    try testing.expectEqual(@as(u64, 123456789), job.difficulty);
    try testing.expectEqual(@as(i64, 7), job.miniblocks);
    try testing.expectEqual(@as(i64, 2), job.blocks);
    try testing.expectEqual(@as(i64, 1), job.rejected);
    // Verify the blob decoded correctly.
    try testing.expectEqual(@as(u8, 0x01), job.blob[0]);
    try testing.expectEqual(@as(u8, 0x30), job.blob[47]);

    // Field order independence.
    const json2 = "{\"difficultyuint64\":999,\"height\":1,\"jobid\":\"x\",\"blockhashing_blob\":\"" ++ blob_hex ++ "\"}";
    const job2 = try parseJob(json2, null);
    try testing.expectEqual(@as(u64, 999), job2.difficulty);
    try testing.expectEqualStrings("x", job2.jobid());
}

test "parseJob guards: missing fields, bad blob length, lasterror" {
    const good_blob = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30";

    // Missing blob.
    try testing.expectError(error.MissingBlob, parseJob("{\"jobid\":\"x\"}", null));
    // Missing jobid.
    try testing.expectError(error.MissingJobid, parseJob("{\"blockhashing_blob\":\"" ++ good_blob ++ "\"}", null));
    // Bad blob length (too short).
    try testing.expectError(error.BadBlobLen, parseJob("{\"jobid\":\"x\",\"blockhashing_blob\":\"abcd\"}", null));

    // lasterror surfaced.
    var le: ?[]const u8 = null;
    _ = parseJob("{\"lasterror\":\"daemon busy\",\"jobid\":\"x\",\"blockhashing_blob\":\"" ++ good_blob ++ "\"}", &le) catch {};
    try testing.expect(le != null);
    try testing.expectEqualStrings("daemon busy", le.?);
}

test "buildSubmit exact format" {
    var out: [256]u8 = undefined;
    const blob_hex = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff001122334455";
    const msg = try buildSubmit(&out, .{ .jobid = "686f.cafe.0001", .mbl_blob_hex = blob_hex });
    try testing.expectEqualStrings(
        "{\"jobid\":\"686f.cafe.0001\",\"mbl_blob\":\"" ++ blob_hex ++ "\"}",
        msg,
    );
}

test "jsonInt tolerant scanning" {
    try testing.expectEqual(@as(i64, 42), jsonInt("{\"a\":42}", "a"));
    try testing.expectEqual(@as(i64, 42), jsonInt("{\"a\": 42 }", "a")); // leading ws
    try testing.expectEqual(@as(i64, -5), jsonInt("{\"a\":-5}", "a"));
    try testing.expectEqual(@as(i64, 0), jsonInt("{\"a\":\"notanint\"}", "a")); // string
    try testing.expectEqual(@as(i64, 0), jsonInt("{\"b\":1}", "a")); // miss
    // difficultyuint64 near u64 max round-trips through i64 bitcast.
    const big_diff: u64 = 0xFFFFFFFFFFFFFFFF;
    var buf: [64]u8 = undefined;
    const j = std.fmt.bufPrint(&buf, "{{\"d\":{d}}}", .{@as(i64, @bitCast(big_diff))}) catch unreachable;
    try testing.expectEqual(big_diff, @as(u64, @bitCast(jsonInt(j, "d"))));
}
