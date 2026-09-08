const std = @import("std");

/// 双方共用一个队列，同时最多处理五名玩家的资料。
pub const Queue = struct {
    next: std.atomic.Value(usize) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    count: usize,
    context: *anyopaque,
    execute: *const fn (*anyopaque, usize) void,

    fn worker(self: *Queue) void {
        while (!self.cancelled.load(.acquire)) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.count) return;
            if (self.cancelled.load(.acquire)) return;
            self.execute(self.context, index);
        }
    }

    pub fn run(self: *Queue) void {
        var threads: [4]?std.Thread = .{null} ** 4;
        for (&threads) |*thread| thread.* = std.Thread.spawn(.{}, worker, .{self}) catch null;
        self.worker();
        for (threads) |thread| if (thread) |value| value.join();
    }
};

test "首名玩家较慢时其余九名照常完成且并发有上限" {
    const Context = struct {
        active: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),
        completed: std.atomic.Value(usize) = .init(0),
        slow_saw: usize = 0,
        gate: std.Io.Semaphore = .{},
        fn execute(pointer: *anyopaque, index: usize) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak.fetchMax(active, .monotonic);
            if (index == 0) {
                self.gate.waitUncancelable(std.testing.io);
                self.slow_saw = self.completed.load(.acquire);
            }
            _ = self.active.fetchSub(1, .acq_rel);
            if (self.completed.fetchAdd(1, .acq_rel) + 1 == 9) self.gate.post(std.testing.io);
        }
    };
    var context = Context{};
    var queue = Queue{ .count = 10, .context = &context, .execute = Context.execute };
    queue.run();
    try std.testing.expectEqual(@as(usize, 9), context.slow_saw);
    try std.testing.expectEqual(@as(usize, 10), context.completed.load(.acquire));
    try std.testing.expect(context.peak.load(.acquire) <= 5);
}

test "取消会话后不再启动排队玩家" {
    const Context = struct {
        fn execute(_: *anyopaque, _: usize) void { @panic("已取消的任务不应启动"); }
    };
    var dummy: u8 = 0;
    var queue = Queue{ .count = 10, .context = &dummy, .execute = Context.execute };
    queue.cancelled.store(true, .release);
    queue.run();
    try std.testing.expectEqual(@as(usize, 0), queue.next.load(.acquire));
}
