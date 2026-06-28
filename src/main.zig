//! main.zig -- DIRTYBIRD/Zig miner entry point. AstroBWTv3 DERO CPU miner.
const std = @import("std");
const builtin = @import("builtin");
const pow = @import("pow.zig");
const miner = @import("miner.zig");
const state = @import("state.zig");
const net = @import("net.zig");
const system = @import("system.zig");
const config = @import("config.zig");
const console = @import("console.zig");
const pages = @import("pages.zig");
const cpu_features = @import("cpu_features.zig");

const VERSION = "0.2.0";

var G: state.MinerState = .{};

// std.time.milliTimestamp / std.time.sleep were removed in Zig 0.16. We use the libc
// clock_gettime / nanosleep wrappers we already link (build.zig: linkLibC, linkLibCpp).
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

// ---- net integration: glue MinerState to net.Hooks ----
const Ctx = struct {
    s: *state.MinerState,
    share_jobid: [state.MAX_JOBID]u8 = undefined,
    share_blob: [state.BLOB_LEN * 2]u8 = undefined,
};

fn onJob(ctx_ptr: *anyopaque, job: *const net.Job) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    _ = ctx.s.setJob(&job.blob, job.jobid(), job.height, job.difficulty);
    ctx.s.accepted.store(job.miniblocks, .monotonic);
    ctx.s.blocks.store(job.blocks, .monotonic);
    ctx.s.rejected.store(job.rejected, .monotonic);
}

fn pollShare(ctx_ptr: *anyopaque) ?net.Share {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const staged = ctx.s.takeStagedShare(&ctx.share_jobid, &ctx.share_blob) orelse return null;
    _ = ctx.s.submitted.fetchAdd(1, .monotonic);
    return net.Share{
        .jobid = ctx.share_jobid[0..staged.jobid_len],
        .mbl_blob_hex = &ctx.share_blob,
    };
}

fn setConnected(ctx_ptr: *anyopaque, connected: bool) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    ctx.s.connected.store(connected, .monotonic);
}

/// net.zig's log sink: route its INFO/WARN/ERROR lines (Connecting/Connected/...) through
/// the timestamped console logger. ctx is unused -- the console writes to the shared stderr.
fn netLog(ctx_ptr: *anyopaque, level: []const u8, msg: []const u8) void {
    _ = ctx_ptr;
    console.logLineRaw(level, msg);
}

fn shouldQuit(ctx_ptr: *anyopaque) bool {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    return ctx.s.quit.load(.monotonic);
}

// ---- Ctrl-C handling (Windows) ----
fn ctrlHandler(dwCtrlType: u32) callconv(.C) std.os.windows.BOOL {
    _ = dwCtrlType;
    G.quit.store(true, .monotonic);
    return std.os.windows.TRUE;
}

fn installSignalHandler() void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleCtrlHandler(ctrlHandler, std.os.windows.TRUE);
    } else {
        const handler = struct {
            fn h(_: std.posix.SIG) callconv(.c) void {
                G.quit.store(true, .monotonic);
            }
        }.h;
        // std.posix.empty_sigset was removed in 0.16. `sigset_t` is a small fixed-size
        // array; an all-zero bit pattern is the empty set per POSIX.
        const empty_mask: std.posix.system.sigset_t = std.mem.zeroes(std.posix.system.sigset_t);
        const act = std.posix.Sigaction{ .handler = .{ .handler = handler }, .mask = empty_mask, .flags = 0 };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
}

fn usage() void {
    std.debug.print(
        \\Usage: zig-miner [-d [ws://|wss://]host:port] [-w wallet] [-t threads] [-c config.json] [-V] [--selftest]
        \\  -d  daemon/pool address [scheme://]host:port  (default community-pools.mysrv.cloud:10300)
        \\        DERO getwork (local derod AND pools) is TLS: bare and wss:// connect over TLS.
        \\        ws:// forces plaintext (only for getwork behind a TLS-terminating proxy).
        \\  -w  DERO wallet address            (default from config.json / built-in)
        \\  -t  mining threads                 (default: logical CPU count)
        \\  -c, --config-file <path>           config file (default: config.json)
        \\  -V  verbose
        \\  --selftest  run pow("a") KAT and exit (0=PASS,1=FAIL)
        \\  --setup     interactively write config.json (pool/wallet/threads), then exit
        \\  -h, --help / -v, --version
        \\
    , .{});
}

/// Run the pow("a") known-answer test, writing the lowercase hex digest into `hex_out`.
/// Returns true on the expected digest. Pure (no printing) so both the startup KAT (silent
/// on success, like the C miner) and the `--selftest` command can share it.
fn powKat(alloc: std.mem.Allocator, hex_out: *[64]u8) !bool {
    const w = try alloc.create(pow.Worker);
    defer alloc.destroy(w);
    w.* = .{};
    defer w.deinitSA();
    var out: [32]u8 = undefined;
    try pow.hash("a", &out, w);
    _ = std.fmt.bufPrint(hex_out, "{s}", .{std.fmt.bytesToHex(&out, .lower)}) catch unreachable;
    const expected = "54e2324ddacc3f0383501a9e5760f85d63e9bc6705e9124ca7aef89016ab81ea";
    return std.mem.eql(u8, hex_out, expected);
}

fn selftest(alloc: std.mem.Allocator) !u8 {
    var hex: [64]u8 = undefined;
    const pass = try powKat(alloc, &hex);
    std.debug.print("selftest pow(a): {s} {s}\n", .{ hex, if (pass) "PASS" else "FAIL" });
    return if (pass) 0 else 1;
}

var g_verbose = false;

// ANSI SGR colors matching the C miner (dirtybird-miner src/main.cpp). The reporter
// forces the colored in-place banner even when stderr is not detected as a TTY.
const A_RESET = "\x1b[0m";
const A_CLREOL = "\x1b[K";
const A_BYELLOW = "\x1b[93m";
const A_BGREEN = "\x1b[92m";
const A_BWHITE = "\x1b[97m";
const A_GREEN = "\x1b[32m";
const A_BLUE = "\x1b[34m";
const A_CYAN = "\x1b[36m";
const A_MAGENTA = "\x1b[35m";
const A_WHITE = "\x1b[37m";
const A_BRED = "\x1b[91m";

/// Humanize difficulty to K/M/G via integer division (matches the C reporter).
fn fmtDiff(buf: []u8, d: u64) []const u8 {
    if (d >= 1_000_000_000) return std.fmt.bufPrint(buf, "{d}G", .{d / 1_000_000_000}) catch "?";
    if (d >= 1_000_000) return std.fmt.bufPrint(buf, "{d}M", .{d / 1_000_000}) catch "?";
    if (d >= 1_000) return std.fmt.bufPrint(buf, "{d}K", .{d / 1_000}) catch "?";
    return std.fmt.bufPrint(buf, "{d}", .{d}) catch "?";
}

const ReportStats = struct {
    rate: f64,
    avg: f64,
    height: i64,
    accepted: i64,
    blocks: i64,
    rejected: i64,
    diff: []const u8,
    hh: u64,
    mm: u64,
    ss: u64,
    verbose: bool = false,
    submitted: i64 = 0,
    stale_drops: i64 = 0,
    submit_drops: i64 = 0,
};

fn formatStatusLine(buf: []u8, stats: ReportStats) []const u8 {
    return formatStatusLineChecked(buf, stats) catch "\r" ++ A_CLREOL;
}

fn formatStatusLineChecked(buf: []u8, stats: ReportStats) ![]const u8 {
    const rejcol = if (stats.rejected > 0) A_BRED else A_WHITE;
    var writer = std.Io.Writer.fixed(buf);

    try writer.print("\r{s}[DIRTYBIRD] ", .{A_BYELLOW});
    try writer.print("{s}{d:.2} KH/s{s} ({s}{d:.2} KH/s avg{s})", .{
        A_BGREEN, stats.rate, A_BWHITE, A_GREEN, stats.avg, A_BWHITE,
    });
    try writer.print(" | {s}Height:{d}{s}", .{ A_BLUE, stats.height, A_BWHITE });
    try writer.print(" | {s}Miniblocks:{d}{s}", .{ A_CYAN, stats.accepted, A_BWHITE });
    try writer.print(" | {s}Blocks:{d}{s}", .{ A_GREEN, stats.blocks, A_BWHITE });
    try writer.print(" | {s}REJ:{d}{s}", .{ rejcol, stats.rejected, A_BWHITE });
    try writer.print(" | {s}Diff:{s}{s}", .{ A_MAGENTA, stats.diff, A_BWHITE });
    try writer.print(" | {s}{d:0>2}:{d:0>2}:{d:0>2}{s}", .{ A_WHITE, stats.hh, stats.mm, stats.ss, A_BWHITE });
    if (stats.verbose) {
        try writer.print(" | funnel submitted:{d} acc:{d} rej:{d} stale:{d} sendfail:{d}", .{
            stats.submitted, stats.accepted, stats.rejected, stats.stale_drops, stats.submit_drops,
        });
    }
    try writer.print("{s}{s}", .{ A_RESET, A_CLREOL });
    return buf[0..writer.end];
}

fn reporter() void {
    var prev: i64 = 0;
    const t0 = nowMsMonotonic();
    var prev_t = t0;

    while (!G.quit.load(.monotonic)) {
        sleepMs(1000);
        const now = nowMsMonotonic();
        const dt = @as(f64, @floatFromInt(now - prev_t)) / 1000.0;
        const elapsed = @as(f64, @floatFromInt(now - t0)) / 1000.0;
        prev_t = now;
        const total = G.total_hashes.load(.monotonic);
        const delta = total - prev;
        prev = total;
        const rate = if (dt > 0) @as(f64, @floatFromInt(delta)) / (dt * 1000.0) else 0;
        const avg = if (elapsed > 0) @as(f64, @floatFromInt(total)) / (elapsed * 1000.0) else 0;
        const sec: u64 = @intFromFloat(elapsed);
        const hh = sec / 3600;
        const mm = (sec % 3600) / 60;
        const ss = sec % 60;

        const height = G.height.load(.monotonic);
        const accepted = G.accepted.load(.monotonic);
        const blocks = G.blocks.load(.monotonic);
        const rejected = G.rejected.load(.monotonic);
        var dbuf: [24]u8 = undefined;
        const diff = fmtDiff(&dbuf, G.difficulty.load(.monotonic));

        var line_buf: [1024]u8 = undefined;
        const line = formatStatusLine(&line_buf, .{
            .rate = rate,
            .avg = avg,
            .height = height,
            .accepted = accepted,
            .blocks = blocks,
            .rejected = rejected,
            .diff = diff,
            .hh = hh,
            .mm = mm,
            .ss = ss,
            .verbose = g_verbose,
            .submitted = G.submitted.load(.monotonic),
            .stale_drops = G.stale_drops.load(.monotonic),
            .submit_drops = G.submit_drops.load(.monotonic),
        });
        std.debug.print("{s}", .{line});
    }
}

test "formatStatusLine always rewrites one colored status row" {
    var buf: [512]u8 = undefined;
    const line = formatStatusLine(&buf, .{
        .rate = 23.76,
        .avg = 20.71,
        .height = 7212998,
        .accepted = 1998,
        .blocks = 262,
        .rejected = 4,
        .diff = "20K",
        .hh = 0,
        .mm = 0,
        .ss = 5,
    });

    try std.testing.expect(std.mem.startsWith(u8, line, "\r" ++ A_BYELLOW ++ "[DIRTYBIRD] "));
    try std.testing.expect(std.mem.indexOf(u8, line, "Height:7212998") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    try std.testing.expect(std.mem.endsWith(u8, line, A_RESET ++ A_CLREOL));
}

test "formatStatusLine appends verbose counters to the same row" {
    var buf: [512]u8 = undefined;
    const line = formatStatusLine(&buf, .{
        .rate = 1.0,
        .avg = 2.0,
        .height = 3,
        .accepted = 4,
        .blocks = 5,
        .rejected = 6,
        .diff = "7K",
        .hh = 8,
        .mm = 9,
        .ss = 10,
        .verbose = true,
        .submitted = 11,
        .stale_drops = 12,
        .submit_drops = 13,
    });

    try std.testing.expect(std.mem.indexOf(u8, line, " | funnel submitted:11 acc:4 rej:6 stale:12 sendfail:13") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    try std.testing.expect(std.mem.endsWith(u8, line, A_RESET ++ A_CLREOL));
}

/// Parse "[wss://|ws://]host:port" into G.host/G.port and pick the transport (G.tls).
/// DERO getwork -- a local `derod` daemon (`Getwork_server` listens with `AddrsTLS` + a
/// self-signed cert) AND public pools -- is TLS (`wss://`), which is why every miner uses
/// verify-none. So a bare address defaults to TLS; `wss://` is explicit TLS; `ws://` forces
/// plaintext (only useful if getwork is fronted by a TLS-terminating proxy). Port optional
/// (keeps the current port on parse failure). Shared by -d and the config.json daemon-address.
fn setDaemon(hp_in: []const u8) void {
    var hp = hp_in;
    var explicit_tls: ?bool = null;
    if (std.mem.startsWith(u8, hp, "wss://")) {
        explicit_tls = true;
        hp = hp["wss://".len..];
    } else if (std.mem.startsWith(u8, hp, "ws://")) {
        explicit_tls = false;
        hp = hp["ws://".len..];
    }
    // Tolerate a trailing path (e.g. wss://host:port/ws/...) -- the wallet supplies the path.
    if (std.mem.indexOfScalar(u8, hp, '/')) |slash| hp = hp[0..slash];
    if (std.mem.lastIndexOfScalar(u8, hp, ':')) |c| {
        G.host = hp[0..c];
        G.port = std.fmt.parseInt(u16, hp[c + 1 ..], 10) catch G.port;
    } else G.host = hp;
    G.tls = explicit_tls orelse true; // DERO getwork is TLS; bare addresses connect over wss://
}

/// Absolute path to config.json next to the running executable, or null if unresolved.
/// std.fs.selfExeDirPathAlloc was removed in 0.16; resolve via readlink(/proc/self/exe)
/// on Linux, _NSGetExecutablePath on macOS, GetModuleFileNameW on Windows. We only
/// port the Linux path here (the miner is Linux/Windows primary; macOS is bonus).
fn exeConfigPath(io: std.Io, alloc: std.mem.Allocator) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &buf) catch return null;
    const full = buf[0..n];
    const slash = std.mem.lastIndexOfScalar(u8, full, '/') orelse return null;
    const dir = full[0..slash];
    return std.fs.path.join(alloc, &.{ dir, "config.json" }) catch null;
}

/// Read one trimmed line from stdin; null on empty/EOF (caller keeps the current value).
/// std.io.getStdIn().reader().readUntilDelimiterOrEof was removed in 0.16; do a direct
/// libc read(2) loop on stdin -- enough for the --setup interactive prompts.
fn promptLine(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos + 1 < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[pos .. pos + 1]) catch return null;
        if (n == 0) {
            if (pos == 0) return null;
            break;
        }
        if (buf[pos] == '\n') break;
        pos += 1;
    }
    buf[pos] = 0;
    const slice = buf[0..pos];
    const t = std.mem.trim(u8, slice, " \t\r\n");
    return if (t.len == 0) null else t;
}

/// Load config `path` (absolute or cwd-relative) and apply daemon/wallet/threads as
/// defaults; CLI flags parsed afterwards override these. Returns true if the file was
/// read+parsed. `cfg_threads` receives the raw threads value (for --setup's display).
/// A missing/invalid file is non-fatal (returns false).
fn loadConfig(io: std.Io, alloc: std.mem.Allocator, path: []const u8, nthreads: *usize, cfg_threads: *i64) bool {
    const cwd = std.Io.Dir.cwd();
    // 0.16 has no `Dir.readFileAbsolute`; open + readAll via Io.Reader interface.
    const file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        cwd.openFile(io, path, .{})) catch return false;
    defer file.close(io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    // Io.Reader.readAlloc allocates exactly `len` bytes and reads into them; we cap at
    // the historical 64 KiB so a runaway config file is rejected.
    const bytes = reader.interface.readAlloc(alloc, 64 * 1024) catch return false;
    defer alloc.free(bytes);
    const c = config.parseConfig(alloc, bytes) catch |e| {
        std.debug.print("warning: could not parse {s}: {s}\n", .{ path, @errorName(e) });
        return false;
    };
    if (c.daemon_address) |hp| setDaemon(hp);
    if (c.wallet) |w| G.wallet = w;
    if (c.threads) |t| {
        cfg_threads.* = t;
        if (t > 0) nthreads.* = @intCast(t);
    }
    return true;
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    defer arg_it.deinit();
    var first = true;
    while (arg_it.next()) |arg| {
        if (first) {
            first = false;
            continue; // skip argv[0]
        }
        try args_list.append(alloc, arg);
    }
    const args = try args_list.toOwnedSlice(alloc);
    defer alloc.free(args);

    var do_selftest = false;
    var do_setup = false;
    var nthreads: usize = 0;
    var cfg_threads: i64 = -1; // raw config threads value (for --setup's "current" display)

    // -c/--config-file override, scanned up-front (also consumed in the loop below).
    var explicit_cfg: ?[]const u8 = null;
    {
        var j: usize = 0;
        while (j < args.len) : (j += 1) {
            if ((std.mem.eql(u8, args[j], "-c") or std.mem.eql(u8, args[j], "--config-file")) and j + 1 < args.len) {
                explicit_cfg = args[j + 1];
            }
        }
    }

    // Load config.json: explicit -c, else next to the executable, else the working dir.
    // CLI flags below override it; a missing file is reported (no silent fallback).
    {
        var loaded = false;
        if (explicit_cfg) |p| {
            loaded = loadConfig(init.io, alloc, p, &nthreads, &cfg_threads);
        } else {
            if (exeConfigPath(init.io, alloc)) |ep| {
                defer alloc.free(ep);
                loaded = loadConfig(init.io, alloc, ep, &nthreads, &cfg_threads);
            }
            if (!loaded) loaded = loadConfig(init.io, alloc, "config.json", &nthreads, &cfg_threads);
        }
        if (!loaded) std.debug.print("config : no config.json found (next to the exe or in the working dir) -- using built-in defaults\n", .{});
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-d") and i + 1 < args.len) {
            i += 1;
            setDaemon(args[i]);
        } else if ((std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--config-file")) and i + 1 < args.len) {
            i += 1; // already applied in the config-loading block above
        } else if (std.mem.eql(u8, a, "-w") and i + 1 < args.len) {
            i += 1;
            G.wallet = args[i];
        } else if (std.mem.eql(u8, a, "-t") and i + 1 < args.len) {
            i += 1;
            nthreads = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--verbose")) {
            g_verbose = true;
        } else if (std.mem.eql(u8, a, "--selftest")) {
            do_selftest = true;
        } else if (std.mem.eql(u8, a, "--setup")) {
            do_setup = true;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--priority")) {
            i += 1; // accepted for CLI compatibility; not yet used
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
            return 0;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version")) {
            std.debug.print("zig-miner v{s}\n", .{VERSION});
            return 0;
        } else {
            usage();
            return 1;
        }
    }

    // Interactive editor: writes config.json next to the exe (the same file the binary
    // reads), so start.bat and a hand-edited config.json are the one persistent knob.
    if (do_setup) {
        var dbuf: [128]u8 = undefined;
        const cur_daemon = std.fmt.bufPrint(&dbuf, "{s}:{d}", .{ G.host, G.port }) catch "community-pools.mysrv.cloud:10300";
        var in_d: [256]u8 = undefined;
        var in_w: [256]u8 = undefined;
        var in_t: [64]u8 = undefined;
        std.debug.print("Setup -- press Enter to keep the current value.\n", .{});
        std.debug.print("  Daemon/pool host:port [{s}]: ", .{cur_daemon});
        const daemon = promptLine(&in_d) orelse cur_daemon;
        std.debug.print("  DERO wallet [{s}]: ", .{G.wallet});
        const wallet = promptLine(&in_w) orelse G.wallet;
        std.debug.print("  Threads (-1 = auto) [{d}]: ", .{cfg_threads});
        const threads: i64 = if (promptLine(&in_t)) |s| (std.fmt.parseInt(i64, s, 10) catch cfg_threads) else cfg_threads;

        var wpath_owned: ?[]u8 = null;
        defer if (wpath_owned) |p| alloc.free(p);
        const wpath: []const u8 = if (explicit_cfg) |p| p else blk: {
            wpath_owned = exeConfigPath(init.io, alloc);
            break :blk (wpath_owned orelse "config.json");
        };
        const f = (if (std.fs.path.isAbsolute(wpath))
            std.Io.Dir.createFileAbsolute(init.io, wpath, .{})
        else
            std.Io.Dir.cwd().createFile(init.io, wpath, .{})) catch |e| {
            std.debug.print("error: could not write {s}: {s}\n", .{ wpath, @errorName(e) });
            return 1;
        };
        defer f.close(init.io);
        var wbuf: [4096]u8 = undefined;
        config.writeConfig(f.writer(init.io, &wbuf), daemon, wallet, threads) catch |e| {
            std.debug.print("error: writing config: {s}\n", .{@errorName(e)});
            return 1;
        };
        std.debug.print("saved {s}\n", .{wpath});
        return 0;
    }

    if (do_selftest) return selftest(alloc);

    if (G.wallet.len == 0) {
        std.debug.print("error: -w <wallet> is required\n", .{});
        usage();
        return 1;
    }

    if (nthreads == 0) nthreads = std.Thread.getCpuCount() catch 4;
    G.nthreads = nthreads;

    // Startup banner -- timestamped INFO lines matching the Dirtybird C miner.
    console.logLine("INFO", "Dirtybird Miner", .{});
    console.logLine("INFO", "Server:  {s}://{s}:{d}", .{ if (G.tls) "wss" else "ws", G.host, G.port });
    console.logLine("INFO", "Wallet:  {s}", .{G.wallet});
    console.logLine("INFO", "Threads: {d}", .{nthreads});
    cpu_features.log(cpu_features.detect());
    std.debug.print("\n", .{}); // blank line before Connecting (C: trailing printf("\n"))

    // Startup KAT (matches the C miner's pow("a") check; silent on success, like the C).
    {
        var hex: [64]u8 = undefined;
        if (!try powKat(alloc, &hex)) {
            console.logLine("ERROR", "pow(\"a\") self-test failed; refusing to mine.", .{});
            return 1;
        }
    }

    installSignalHandler();

    // Max-performance profile (matches the C miner's `-p max`): HIGH priority
    // class + SeLockMemoryPrivilege; per-thread P-core pinning is done in mineThread.
    if (builtin.os.tag == .windows) {
        _ = system.enableLockMemoryPrivilege();
        system.setProcessHighPriority();
        system.enableVirtualTerminal(); // ANSI colors for the status line
    }

    // Mining-thread workers: TWO per thread (one per lane of the batched, 2-way
    // multi-buffer SHA in mineThread/pow.hash2). Each thread's lane pair (indices
    // 2*idx and 2*idx+1) is packed into one huge-page backing when the OS grants it
    // (Windows large pages; Linux THP request), falling back to heap allocation.
    const workers = try alloc.alloc(*pow.Worker, nthreads * 2);
    defer alloc.free(workers);
    // Per-pair large-page backing: backings[idx] is the 2-worker block for lane
    // pair idx, or null if that pair came from the heap. Declared (and its free
    // defer registered) BEFORE the worker-cleanup defer so LIFO keeps both
    // `backings` and `workers` valid while cleanup runs.
    const backings = try alloc.alloc(?pages.PageBacking, nthreads);
    defer alloc.free(backings);
    for (backings) |*b| b.* = null;
    // Cleanup over the successfully-created prefix: exactly `created` workers and
    // their backings are released on any exit -- a partial-construction OOM error
    // or normal shutdown -- with no leak and no double-free. Two-phase: deinitSA
    // every created worker FIRST, then free the backings. Both workers of a packed
    // pair live inside the same large-page block, and deinitSA reads fields inside
    // that block, so the block must not be freed until both have been deinit'd.
    var created: usize = 0;
    defer {
        for (workers[0..created]) |wp| wp.deinitSA();
        for (backings) |b| {
            if (b) |backing| pages.freeHugeBacking(backing);
        }
        // Heap-allocated workers (no large-page backing for their pair) are freed
        // individually. A pair is heap-backed iff backings[pair] is null.
        for (workers[0..created], 0..) |wp, wi| {
            if (backings[wi / 2] == null) alloc.destroy(wp);
        }
    }
    {
        var idx: usize = 0;
        while (idx < nthreads) : (idx += 1) {
            const lane0 = 2 * idx;
            const lane1 = lane0 + 1;
            // Try one huge-page backing for the lane pair. On success both workers
            // live in it and `created` jumps by 2 with no fallible op in between,
            // so a huge-page pair is always complete (never half-built).
            if (pages.allocHugeBacking(2 * @sizeOf(pow.Worker))) |backing| {
                backings[idx] = backing;
                const buf = backing.bytes;
                const w0: *pow.Worker = @ptrCast(@alignCast(buf.ptr));
                const w1: *pow.Worker = @ptrCast(@alignCast(buf.ptr + @sizeOf(pow.Worker)));
                w0.* = .{};
                w1.* = .{};
                workers[lane0] = w0;
                created += 1;
                workers[lane1] = w1;
                created += 1;
                continue;
            }
            // Heap fallback: each worker is created independently so a `try` OOM
            // mid-pair leaves `created` exact (odd if w0 succeeded but w1 failed),
            // and cleanup frees only what was built.
            workers[lane0] = try alloc.create(pow.Worker);
            workers[lane0].* = .{};
            created += 1;
            workers[lane1] = try alloc.create(pow.Worker);
            workers[lane1].* = .{};
            created += 1;
        }
    }

    // Report actual huge-page-backed pairs. Linux THP is advisory: successful
    // madvise means requested, not guaranteed resident huge pages.
    if (builtin.os.tag == .windows or builtin.os.tag == .linux) {
        var backed_pairs: usize = 0;
        var mapped_mb: usize = 0;
        for (backings) |b| {
            if (b) |backing| {
                backed_pairs += 1;
                mapped_mb += backing.mappedLen() / (1024 * 1024);
            }
        }
        if (builtin.os.tag == .windows) {
            console.logLine("INFO", "Large pages: {d}/{d} worker pairs ({d} MB locked)", .{ backed_pairs, nthreads, mapped_mb });
        } else {
            console.logLine("INFO", "Huge pages: {d}/{d} worker pairs (THP requested, {d} MB mapped)", .{ backed_pairs, nthreads, mapped_mb });
        }
    }

    var ctx = Ctx{ .s = &G };
    const hooks = net.Hooks{
        .ctx = &ctx,
        .on_job = onJob,
        .poll_share = pollShare,
        .set_connected = setConnected,
        .log = netLog,
        .should_quit = shouldQuit,
    };
    const cfg = net.Config{ .host = G.host, .port = G.port, .wallet = G.wallet, .tls = G.tls };

    const net_thread = try std.Thread.spawn(.{}, net.run, .{ alloc, cfg, hooks });
    const rpt_thread = try std.Thread.spawn(.{}, reporter, .{});

    const miners = try alloc.alloc(std.Thread, nthreads);
    defer alloc.free(miners);
    for (miners, 0..) |*t, idx| t.* = try std.Thread.spawn(.{}, miner.mineThread, .{ &G, idx, workers[2 * idx], workers[2 * idx + 1] });

    for (miners) |t| t.join();
    net_thread.join();
    rpt_thread.join();

    std.debug.print("\nShutdown. {d} hashes, {d} miniblocks ({d} blocks), {d} rejected.\n", .{
        G.total_hashes.load(.monotonic), G.accepted.load(.monotonic), G.blocks.load(.monotonic), G.rejected.load(.monotonic),
    });
    return 0;
}
