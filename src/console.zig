//! console.zig -- timestamped INFO/WARN/ERROR log lines matching the Dirtybird C
//! miner's `console.cpp::log_line`. Imported by main.zig ONLY; net.zig stays portable
//! and reaches logging through the net.Hooks `log` callback instead of importing this.
//!
//! C reference (src/console.cpp):
//!   TTY:      printf("\r%s%s.%03d  %-5s %s\n", clr_eol, ts, ms, level, msg)
//!   non-TTY:  printf("%s.%03d  %-5s %s\n", ts, ms, level, msg)
//!   ts = strftime("%d/%m %H:%M:%S", localtime), clr_eol = "\x1b[K".
//! The C writes to stdout; we use stderr (std.debug.print) to share the one stream --
//! and lock -- the reporter already uses (main.zig). Visually identical.
//! The Zig miner forces the leading CR+clear sequence for every log line so a later
//! INFO/WARN/ERROR line never lands in the middle of the live status banner.
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const A_CLREOL = "\x1b[K"; // ANSI erase-to-end-of-line (C's dluna_clr_eol)

/// Broken-down LOCAL wall-clock time to the millisecond (C: localtime + .%03d ms).
const LocalTime = struct { month: u8, day: u8, hour: u8, minute: u8, second: u8, millis: u16 };

// Windows GetLocalTime gives every field (incl. milliseconds) directly. Declared at top
// level but referenced only in the is_windows branch, so the POSIX build prunes it.
const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};
extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;

// POSIX `struct tm` (LP64 glibc/musl ABI: 9 ints + the gmtoff/zone extensions) and
// localtime_r. Hand-declared because Zig 0.14's std.c exposes neither `tm` nor `localtime_r`.
// Referenced only in the POSIX branch, so the Windows build prunes them (and never links
// libc's localtime_r). time_t is `long` (= c_long, 64-bit) on the x86_64/aarch64 targets.
const CTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(timer: *const c_long, result: *CTm) ?*CTm;

fn nowLocal() LocalTime {
    if (is_windows) {
        var st: SYSTEMTIME = undefined;
        GetLocalTime(&st);
        return .{
            .month = @intCast(st.wMonth),
            .day = @intCast(st.wDay),
            .hour = @intCast(st.wHour),
            .minute = @intCast(st.wMinute),
            .second = @intCast(st.wSecond),
            .millis = @intCast(st.wMilliseconds),
        };
    } else {
        // POSIX: localtime_r for the broken-down local fields + clock_gettime(REAL)
        // for sub-second millisecond precision. libC is linked (build.zig: linkLibC).
        // std.time.milliTimestamp was removed in Zig 0.16.
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts);
        const ms_total: i128 = @as(i128, ts.sec) * 1000 + @divTrunc(@as(i128, ts.nsec), std.time.ns_per_ms);
        const t: c_long = @intCast(@divFloor(ms_total, 1000));
        var tm: CTm = undefined;
        _ = localtime_r(&t, &tm);
        return .{
            .month = @intCast(tm.tm_mon + 1),
            .day = @intCast(tm.tm_mday),
            .hour = @intCast(tm.tm_hour),
            .minute = @intCast(tm.tm_min),
            .second = @intCast(tm.tm_sec),
            .millis = @intCast(@mod(ms_total, 1000)),
        };
    }
}

fn formatLogLine(buf: []u8, lt: LocalTime, level: []const u8, msg: []const u8) []const u8 {
    var lvl: [5]u8 = .{ ' ', ' ', ' ', ' ', ' ' };
    const n = @min(level.len, lvl.len);
    @memcpy(lvl[0..n], level[0..n]);

    return std.fmt.bufPrint(buf, "\r{s}{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}  {s} {s}\n", .{
        A_CLREOL, lt.day, lt.month, lt.hour, lt.minute, lt.second, lt.millis, lvl[0..], msg,
    }) catch buf[0..0];
}

/// Print one timestamped log line for a pre-formatted message. `level` is left-padded
/// to width 5 (C's `%-5s`): "INFO "/"WARN "/"ERROR", giving two spaces after "INFO".
/// The leading `\r\x1b[K` overwrites the reporter's in-place stats line.
pub fn logLineRaw(level: []const u8, msg: []const u8) void {
    const lt = nowLocal();
    var buf: [1024]u8 = undefined;
    std.debug.print("{s}", .{formatLogLine(&buf, lt, level, msg)});
}

/// Convenience for callers with a comptime format (the startup banner). Formats into a
/// stack buffer then delegates to logLineRaw. 512 bytes covers a wallet (~66) + label.
pub fn logLine(level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    logLineRaw(level, msg);
}

test "formatLogLine clears any live status row before logging" {
    var buf: [128]u8 = undefined;
    const line = formatLogLine(&buf, .{
        .month = 6,
        .day = 19,
        .hour = 13,
        .minute = 27,
        .second = 12,
        .millis = 466,
    }, "INFO", "Connected");

    try std.testing.expectEqualStrings("\r\x1b[K19/06 13:27:12.466  INFO  Connected\n", line);
}
