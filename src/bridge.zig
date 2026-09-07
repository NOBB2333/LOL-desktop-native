const std = @import("std");
const native_sdk = @import("native_sdk");
const backend = @import("backend");
const build_options = @import("build_options");

const dev_origin = std.fmt.comptimePrint("http://{s}:{d}", .{ build_options.dev_server_host, build_options.dev_server_port });
pub const origin_allowlist = if (build_options.automation)
    [_][]const u8{ "zero://app", "zero://inline", dev_origin }
else
    [_][]const u8{ "zero://app", dev_origin };

/// Keep the bridge policy in one module so command registration cannot drift
/// from the runtime handler list while features are migrated incrementally.
pub const policies = blk: {
    var result: [backend.command_names.len + 1]native_sdk.bridge.CommandPolicy = undefined;
    result[0] = .{ .name = "native.ping", .origins = &origin_allowlist };
    for (backend.command_names, 0..) |name, index| {
        result[index + 1] = .{ .name = name, .origins = &origin_allowlist };
    }
    break :blk result;
};

test "policy covers every backend command" {
    try @import("std").testing.expectEqual(backend.command_names.len + 1, policies.len);
}
