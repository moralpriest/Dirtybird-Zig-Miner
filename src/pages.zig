const std = @import("std");
const builtin = @import("builtin");

const system = if (builtin.os.tag == .windows) @import("system.zig") else struct {};

pub const huge_page_size: usize = 2 * 1024 * 1024;
const page_align = std.heap.page_size_min;

pub const HugeKind = enum {
    windows_large,
    linux_thp_requested,

    pub fn isAdvisory(kind: HugeKind) bool {
        return kind == .linux_thp_requested;
    }

    pub fn label(kind: HugeKind) []const u8 {
        return switch (kind) {
            .windows_large => "large pages",
            .linux_thp_requested => "THP requested",
        };
    }
};

pub const PageBacking = struct {
    mapping: []align(page_align) u8,
    bytes: []align(page_align) u8,
    kind: HugeKind,

    pub fn mappedLen(self: PageBacking) usize {
        return self.mapping.len;
    }
};

const HugeWindow = struct {
    offset: usize,
    len: usize,
};

pub fn roundHugeSize(size: usize) usize {
    if (size == 0) return 0;
    return std.mem.alignForward(usize, size, huge_page_size);
}

pub fn allocHugeBacking(size: usize) ?PageBacking {
    if (size == 0) return null;
    return switch (builtin.os.tag) {
        .windows => allocWindows(size),
        .linux => allocLinuxThp(size),
        else => null,
    };
}

pub fn freeHugeBacking(backing: PageBacking) void {
    switch (backing.kind) {
        .windows_large => {
            if (comptime builtin.os.tag == .windows) {
                system.freeLargePages(@alignCast(backing.bytes));
            }
        },
        .linux_thp_requested => {
            if (comptime builtin.os.tag == .linux) {
                std.posix.munmap(backing.bytes);
            }
        },
    }
}

fn allocWindows(size: usize) ?PageBacking {
    if (comptime builtin.os.tag != .windows) return null;
    const buf = system.allocLargePages(size) orelse return null;
    const bytes: []align(page_align) u8 = @alignCast(buf);
    return .{ .mapping = bytes, .bytes = bytes, .kind = .windows_large };
}

fn allocLinuxThp(size: usize) ?PageBacking {
    if (comptime builtin.os.tag != .linux) return null;
    const window = roundHugeSize(size);
    const mapped_len = window + huge_page_size;
    const flags = std.posix.MAP{
        .TYPE = .PRIVATE,
        .ANONYMOUS = true,
    };
    const mapping = std.posix.mmap(
        null,
        mapped_len,
        .{ .READ = true, .WRITE = true },
        flags,
        -1,
        0,
    ) catch return null;
    const aligned = alignedHugeWindow(@intFromPtr(mapping.ptr), size) orelse {
        std.posix.munmap(mapping);
        return null;
    };
    const aligned_ptr: [*]align(page_align) u8 = @alignCast(mapping.ptr + aligned.offset);
    const bytes = aligned_ptr[0..aligned.len];
    std.posix.madvise(bytes.ptr, bytes.len, std.posix.MADV.HUGEPAGE) catch {
        std.posix.munmap(mapping);
        return null;
    };
    return .{ .mapping = mapping, .bytes = bytes, .kind = .linux_thp_requested };
}

fn alignedHugeWindow(base_addr: usize, requested_size: usize) ?HugeWindow {
    if (requested_size == 0) return null;
    const len = roundHugeSize(requested_size);
    const aligned_addr = std.mem.alignForward(usize, base_addr, huge_page_size);
    return .{ .offset = aligned_addr - base_addr, .len = len };
}

test "roundHugeSize rounds to 2 MiB pages" {
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), roundHugeSize(1));
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), roundHugeSize(2 * 1024 * 1024));
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), roundHugeSize(2 * 1024 * 1024 + 1));
}

test "alignedHugeWindow returns a 2 MiB-aligned usable range" {
    const aligned = alignedHugeWindow(0x200000, 1).?;
    try std.testing.expectEqual(@as(usize, 0), aligned.offset);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), aligned.len);

    const unaligned = alignedHugeWindow(0x1000, 1).?;
    try std.testing.expectEqual(@as(usize, 0x1ff000), unaligned.offset);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), unaligned.len);
}

test "linux page backing kind is advisory" {
    try std.testing.expectEqual(HugeKind.linux_thp_requested, HugeKind.linux_thp_requested);
    try std.testing.expect(HugeKind.linux_thp_requested.isAdvisory());
    try std.testing.expect(!HugeKind.windows_large.isAdvisory());
}
