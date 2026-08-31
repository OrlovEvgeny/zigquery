//! An `Allocator` wrapper that records how much memory a workload asks for.
//!
//! The library under test allocates almost everything through arenas, so the
//! interesting number is not "how many times did `create` get called" but "how
//! many bytes are still checked out when the workload claims to be done".
//! `live` answers that, and a benchmark that leaks shows up as a `live` value
//! that climbs with every iteration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const CountingAllocator = struct {
    backing: Allocator,

    /// Bytes currently checked out.
    live: usize = 0,
    /// High-water mark of `live` since the last `reset`.
    peak: usize = 0,
    /// Every byte ever handed out, including bytes later freed.
    total: usize = 0,
    alloc_count: u64 = 0,
    resize_count: u64 = 0,
    free_count: u64 = 0,

    pub fn init(backing: Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Zero the derived counters and rebase the peak on whatever is currently
    /// checked out. Call this between the warmup and the measured run.
    ///
    /// `live` is deliberately left alone: memory allocated before the reset is
    /// still outstanding and will be freed later, and zeroing `live` here would
    /// make those frees underflow.
    pub fn reset(self: *CountingAllocator) void {
        self.peak = self.live;
        self.total = 0;
        self.alloc_count = 0;
        self.resize_count = 0;
        self.free_count = 0;
    }

    fn note(self: *CountingAllocator, delta: usize) void {
        self.live += delta;
        self.total += delta;
        if (self.live > self.peak) self.peak = self.live;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        self.note(len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resize_count += 1;
        self.applyDelta(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resize_count += 1;
        self.applyDelta(memory.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.free_count += 1;
        self.live -= memory.len;
    }

    fn applyDelta(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.note(new_len - old_len);
        } else {
            self.live -= old_len - new_len;
        }
    }
};

test "counts live bytes and returns to zero" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const a = counting.allocator();

    const first = try a.alloc(u8, 1000);
    try std.testing.expectEqual(@as(usize, 1000), counting.live);

    const second = try a.alloc(u8, 500);
    try std.testing.expectEqual(@as(usize, 1500), counting.live);
    try std.testing.expectEqual(@as(usize, 1500), counting.peak);

    a.free(second);
    try std.testing.expectEqual(@as(usize, 1000), counting.live);
    // The peak remembers the high-water mark even after the free.
    try std.testing.expectEqual(@as(usize, 1500), counting.peak);

    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), counting.live);
    try std.testing.expectEqual(@as(usize, 1500), counting.total);
}

test "reset keeps live so later frees do not underflow" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const a = counting.allocator();

    const held = try a.alloc(u8, 4096);
    try std.testing.expectEqual(@as(usize, 4096), counting.live);

    counting.reset();
    // Still outstanding, so still counted.
    try std.testing.expectEqual(@as(usize, 4096), counting.live);
    try std.testing.expectEqual(@as(usize, 4096), counting.peak);
    try std.testing.expectEqual(@as(usize, 0), counting.total);

    a.free(held);
    try std.testing.expectEqual(@as(usize, 0), counting.live);
}

test "tracks growth through an ArrayList" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const a = counting.allocator();

    var list: std.ArrayList(u32) = .empty;
    for (0..1000) |i| try list.append(a, @intCast(i));
    try std.testing.expect(counting.live > 0);

    list.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), counting.live);
}
