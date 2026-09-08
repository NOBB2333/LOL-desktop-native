pub const Control = struct {
    context: ?*anyopaque = null,
    check_fn: ?*const fn (*anyopaque) anyerror!void = null,

    pub fn check(self: Control) !void {
        if (self.check_fn) |check_fn| try check_fn(self.context.?);
    }
};

test "过期请求在执行网络操作前被拒绝" {
    const std = @import("std");
    const Guard = struct {
        fn check(_: *anyopaque) !void {
            return error.RequestCancelled;
        }
    };
    var value: u8 = 0;
    try std.testing.expectError(error.RequestCancelled, (Control{ .context = &value, .check_fn = Guard.check }).check());
    try (Control{}).check();
}
