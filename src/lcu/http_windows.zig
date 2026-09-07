const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    method: []const u8 = "GET",
    url: []const u8,
    headers: []const u8 = "",
    body: ?[]const u8 = null,
    user_agent: []const u8 = "lol-desktop-native/2.0",
    timeout_ms: u32 = 6000,
    verify_tls: bool = true,
    max_response_bytes: usize = 8 * 1024 * 1024,
};

const ParsedUrl = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub fn request(allocator: std.mem.Allocator, options: Options) ![]u8 {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const parsed = try parseUrl(options.url);
    if (options.max_response_bytes == 0) return error.ResponseTooLarge;

    const agent = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, options.user_agent);
    defer allocator.free(agent);
    const host = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, parsed.host);
    defer allocator.free(host);
    const method = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, options.method);
    defer allocator.free(method);
    const path = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, parsed.path);
    defer allocator.free(path);
    const headers = if (options.headers.len > 0)
        try std.unicode.wtf8ToWtf16LeAllocZ(allocator, options.headers)
    else
        null;
    defer if (headers) |value| allocator.free(value);

    const session = winhttp.WinHttpOpen(agent.ptr, winhttp.access_type_automatic_proxy, null, null, 0) orelse return error.RequestFailed;
    defer _ = winhttp.WinHttpCloseHandle(session);
    const timeout: i32 = @intCast(@min(options.timeout_ms, @as(u32, std.math.maxInt(i32))));
    if (winhttp.WinHttpSetTimeouts(session, timeout, timeout, timeout, timeout) == 0) return error.RequestFailed;

    const connection = winhttp.WinHttpConnect(session, host.ptr, parsed.port, 0) orelse return error.RequestFailed;
    defer _ = winhttp.WinHttpCloseHandle(connection);
    const flags: u32 = if (parsed.secure) winhttp.flag_secure else 0;
    const request_handle = winhttp.WinHttpOpenRequest(connection, method.ptr, path.ptr, null, null, null, flags) orelse return error.RequestFailed;
    defer _ = winhttp.WinHttpCloseHandle(request_handle);

    var decompression: u32 = winhttp.decompression_all;
    _ = winhttp.WinHttpSetOption(request_handle, winhttp.option_decompression, @ptrCast(&decompression), @sizeOf(u32));
    if (parsed.secure and !options.verify_tls) {
        var security_flags: u32 = winhttp.security_ignore_all;
        if (winhttp.WinHttpSetOption(request_handle, winhttp.option_security_flags, @ptrCast(&security_flags), @sizeOf(u32)) == 0) return error.RequestFailed;
    }

    const body = options.body orelse "";
    if (body.len > std.math.maxInt(u32)) return error.RequestTooLarge;
    const body_pointer: ?*anyopaque = if (body.len > 0) @ptrCast(@constCast(body.ptr)) else null;
    const header_pointer: ?[*:0]const u16 = if (headers) |value| value.ptr else null;
    const header_length: u32 = if (headers) |value| @intCast(value.len) else 0;
    if (winhttp.WinHttpSendRequest(
        request_handle,
        header_pointer,
        header_length,
        body_pointer,
        @intCast(body.len),
        @intCast(body.len),
        0,
    ) == 0) return error.RequestFailed;
    if (winhttp.WinHttpReceiveResponse(request_handle, null) == 0) return error.RequestFailed;

    var status: u32 = 0;
    var status_size: u32 = @sizeOf(u32);
    if (winhttp.WinHttpQueryHeaders(
        request_handle,
        winhttp.query_status_code | winhttp.query_flag_number,
        null,
        @ptrCast(&status),
        &status_size,
        null,
    ) == 0) return error.RequestFailed;
    if (status < 200 or status >= 300) return error.HttpStatus;

    var response = try allocator.alloc(u8, @min(@as(usize, 64 * 1024), options.max_response_bytes));
    errdefer allocator.free(response);
    var used: usize = 0;
    while (true) {
        var available: u32 = 0;
        if (winhttp.WinHttpQueryDataAvailable(request_handle, &available) == 0) return error.RequestFailed;
        if (available == 0) break;
        const required = std.math.add(usize, used, available) catch return error.ResponseTooLarge;
        if (required > options.max_response_bytes) return error.ResponseTooLarge;
        if (required > response.len) {
            var next = response.len;
            while (next < required) next = @min(options.max_response_bytes, @max(required, next * 2));
            response = try allocator.realloc(response, next);
        }
        var read: u32 = 0;
        if (winhttp.WinHttpReadData(request_handle, response.ptr + used, available, &read) == 0) return error.RequestFailed;
        if (read == 0) break;
        used += read;
    }
    return allocator.realloc(response, used);
}

fn parseUrl(url: []const u8) !ParsedUrl {
    const secure = if (std.mem.startsWith(u8, url, "https://"))
        true
    else if (std.mem.startsWith(u8, url, "http://"))
        false
    else
        return error.InvalidUrl;
    const authority_start: usize = if (secure) "https://".len else "http://".len;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse url.len;
    const authority = url[authority_start..path_start];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |index| authority[0..index] else authority;
    const port = if (colon) |index|
        std.fmt.parseInt(u16, authority[index + 1 ..], 10) catch return error.InvalidUrl
    else if (secure)
        @as(u16, 443)
    else
        @as(u16, 80);
    if (host.len == 0) return error.InvalidUrl;
    return .{
        .secure = secure,
        .host = host,
        .port = port,
        .path = if (path_start < url.len) url[path_start..] else "/",
    };
}

const winhttp = if (builtin.os.tag == .windows) struct {
    const Handle = *anyopaque;
    const access_type_automatic_proxy: u32 = 4;
    const flag_secure: u32 = 0x00800000;
    const option_security_flags: u32 = 31;
    const option_decompression: u32 = 118;
    const decompression_all: u32 = 0x00000003;
    const security_ignore_all: u32 = 0x00003300;
    const query_status_code: u32 = 19;
    const query_flag_number: u32 = 0x20000000;

    extern "winhttp" fn WinHttpOpen(agent: ?[*:0]const u16, access_type: u32, proxy: ?[*:0]const u16, proxy_bypass: ?[*:0]const u16, flags: u32) callconv(.winapi) ?Handle;
    extern "winhttp" fn WinHttpCloseHandle(handle: Handle) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpConnect(session: Handle, server_name: [*:0]const u16, server_port: u16, reserved: u32) callconv(.winapi) ?Handle;
    extern "winhttp" fn WinHttpOpenRequest(connection: Handle, verb: [*:0]const u16, object_name: [*:0]const u16, version: ?[*:0]const u16, referrer: ?[*:0]const u16, accept_types: ?[*]const ?[*:0]const u16, flags: u32) callconv(.winapi) ?Handle;
    extern "winhttp" fn WinHttpSetTimeouts(handle: Handle, resolve: i32, connect: i32, send: i32, receive: i32) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpSetOption(handle: Handle, option: u32, buffer: *anyopaque, buffer_length: u32) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpSendRequest(request_handle: Handle, headers: ?[*:0]const u16, headers_length: u32, optional: ?*anyopaque, optional_length: u32, total_length: u32, context: usize) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpReceiveResponse(request_handle: Handle, reserved: ?*anyopaque) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpQueryHeaders(request_handle: Handle, info_level: u32, name: ?[*:0]const u16, buffer: ?*anyopaque, buffer_length: *u32, index: ?*u32) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpQueryDataAvailable(request_handle: Handle, available: *u32) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpReadData(request_handle: Handle, buffer: *anyopaque, bytes_to_read: u32, bytes_read: *u32) callconv(.winapi) i32;
} else struct {};

test "parses loopback and SGP URLs" {
    const local = try parseUrl("https://127.0.0.1:2999/liveclientdata/allgamedata");
    try std.testing.expect(local.secure);
    try std.testing.expectEqualStrings("127.0.0.1", local.host);
    try std.testing.expectEqual(@as(u16, 2999), local.port);
    const sgp = try parseUrl("https://hn1-k8s-sgp.lol.qq.com:21019/matches?count=50");
    try std.testing.expectEqualStrings("hn1-k8s-sgp.lol.qq.com", sgp.host);
    try std.testing.expectEqual(@as(u16, 21019), sgp.port);
}
