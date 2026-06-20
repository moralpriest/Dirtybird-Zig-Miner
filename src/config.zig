//! config.zig -- optional config.json read at startup. Uses the same keys as the
//! DeroLuna miner (`daemon-address`, `wallet`, `threads`) so a familiar config.json
//! "just works". Precedence: explicit CLI flags > config.json > compiled-in defaults.
const std = @import("std");

pub const Config = struct {
    daemon_address: ?[]const u8 = null,
    wallet: ?[]const u8 = null,
    threads: ?i64 = null,
};

/// Parse a JSON config. Unknown keys are ignored and any missing key stays null, so a
/// partial or fuller DeroLuna-style config.json is accepted. Returned strings are duped
/// with `allocator` (program-lifetime; freed at process exit).
pub fn parseConfig(allocator: std.mem.Allocator, bytes: []const u8) !Config {
    const Raw = struct {
        @"daemon-address": ?[]const u8 = null,
        wallet: ?[]const u8 = null,
        threads: ?i64 = null,
    };
    var parsed = try std.json.parseFromSlice(Raw, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const r = parsed.value;
    return .{
        .daemon_address = if (r.@"daemon-address") |s| try allocator.dupe(u8, s) else null,
        .wallet = if (r.wallet) |s| try allocator.dupe(u8, s) else null,
        .threads = r.threads,
    };
}

/// Serialize a config to JSON in the exact shape we ship (the 3 keys). Used by `--setup`
/// so the interactive launcher path and a hand-edited config.json stay one file/format.
/// `writer` may be either the legacy `std.io.Writer` (for tests) or `std.Io.File.Writer`
/// (in 0.16+, where `Writer` no longer has `.print`). We format into a fixed buffer and
/// then route through whichever writeAll-style method the writer exposes.
pub fn writeConfig(writer: anytype, daemon_address: []const u8, wallet: []const u8, threads: i64) !void {
    var buf: [1024]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf,
        \\{{
        \\  "daemon-address": "{s}",
        \\  "wallet": "{s}",
        \\  "threads": {d}
        \\}}
        \\
    , .{ daemon_address, wallet, threads });

    const WriterType = @TypeOf(writer);
    if (@hasField(WriterType, "interface")) {
        // 0.16's `std.Io.File.Writer` exposes the underlying `Io.Writer` as `.interface`,
        // but a value receiver arrives here as a `const` so we copy into a local to
        // obtain a mutable reference for `writeAll` (which takes `*Io.Writer`).
        var iface = writer.interface;
        try iface.writeAll(formatted);
    } else if (@hasDecl(WriterType, "writeAll")) {
        try writer.writeAll(formatted);
    } else {
        // Legacy fallback: small loop over .write (rare; tests pass std.io.Writer).
        var pos: usize = 0;
        while (pos < formatted.len) {
            const n = try writer.write(formatted[pos..]);
            if (n == 0) return error.WriteFailed;
            pos += n;
        }
    }
}

test "parseConfig: reads keys, ignores unknown, missing -> null" {
    const a = std.testing.allocator;
    const json =
        \\{
        \\  "daemon-address": "host.example:1234",
        \\  "wallet": "dero1qexample",
        \\  "threads": -1,
        \\  "lock-threads": true,
        \\  "period": 10
        \\}
    ;
    const c = try parseConfig(a, json);
    defer {
        if (c.daemon_address) |s| a.free(s);
        if (c.wallet) |s| a.free(s);
    }
    try std.testing.expectEqualStrings("host.example:1234", c.daemon_address.?);
    try std.testing.expectEqualStrings("dero1qexample", c.wallet.?);
    try std.testing.expectEqual(@as(i64, -1), c.threads.?);

    const c2 = try parseConfig(a, "{}");
    try std.testing.expect(c2.daemon_address == null);
    try std.testing.expect(c2.wallet == null);
    try std.testing.expect(c2.threads == null);
}

test "writeConfig round-trips through parseConfig" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try writeConfig(buf.writer(), "host.example:1234", "dero1qsetup", 12);
    const c = try parseConfig(a, buf.items);
    defer {
        if (c.daemon_address) |s| a.free(s);
        if (c.wallet) |s| a.free(s);
    }
    try std.testing.expectEqualStrings("host.example:1234", c.daemon_address.?);
    try std.testing.expectEqualStrings("dero1qsetup", c.wallet.?);
    try std.testing.expectEqual(@as(i64, 12), c.threads.?);
}
