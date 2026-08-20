//! Loopback HTTP wrapper tests. Default mem/posix stay ENOSYS.

const std = @import("std");
const linux = std.os.linux;
const utilz = @import("utilz");
const sys = utilz.sys;
const mem = utilz.mem;
const http_mod = utilz.http;
const registry = utilz.registry;
const Ctx = utilz.Ctx;

const Http = http_mod.Http;

const body_text = "hello";
const resp = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";

fn startResponder() !struct { port: u16, pid: linux.pid_t } {
    const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    const fds: isize = @bitCast(fd_rc);
    if (fds < 0) return error.TestUnexpectedResult;
    const fd: i32 = @intCast(fds);

    var addr = linux.sockaddr.in{
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    const brc = linux.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    const bsigned: isize = @bitCast(brc);
    if (bsigned < 0) {
        _ = linux.close(fd);
        return error.TestUnexpectedResult;
    }
    const lrc = linux.listen(fd, 1);
    const lsigned: isize = @bitCast(lrc);
    if (lsigned < 0) {
        _ = linux.close(fd);
        return error.TestUnexpectedResult;
    }
    var alen: linux.socklen_t = @sizeOf(@TypeOf(addr));
    const grc = linux.getsockname(fd, @ptrCast(&addr), &alen);
    const gsigned: isize = @bitCast(grc);
    if (gsigned < 0) {
        _ = linux.close(fd);
        return error.TestUnexpectedResult;
    }
    const port = std.mem.bigToNative(u16, addr.port);

    const frc = linux.fork();
    const fsigned: isize = @bitCast(frc);
    if (fsigned < 0) {
        _ = linux.close(fd);
        return error.TestUnexpectedResult;
    }
    if (fsigned == 0) {
        const crc = linux.accept(fd, null, null);
        const csigned: isize = @bitCast(crc);
        if (csigned < 0) linux.exit_group(1);
        const cfd: i32 = @intCast(csigned);
        var junk: [512]u8 = undefined;
        _ = linux.read(cfd, &junk, junk.len);
        _ = linux.write(cfd, resp, resp.len);
        _ = linux.close(cfd);
        _ = linux.close(fd);
        linux.exit_group(0);
    }
    _ = linux.close(fd);
    return .{ .port = port, .pid = @intCast(fsigned) };
}

fn reap(pid: linux.pid_t) void {
    var st: u32 = 0;
    _ = linux.waitpid(pid, &st, 0);
}

fn run(args: []const []const u8) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: [8][:0]const u8 = undefined;
    if (args.len > store.len) return error.TestUnexpectedResult;
    for (args, 0..) |a, i| store[i] = try arena.dupeZ(u8, a);
    const applet = registry.find(args[0]) orelse return error.TestUnexpectedResult;
    var ctx = Ctx{
        .args = store[0..args.len],
        .gpa = arena,
        .stdin = 0,
        .stdout = 1,
        .stderr = 2,
    };
    return applet.run(&ctx);
}

test "fetch and wget against loopback CRLF responder" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    const wrap = try Http.init(std.testing.allocator, world.sysImpl());
    defer wrap.deinit();
    wrap.attach();
    defer sys.detach();

    {
        const srv = try startResponder();
        defer reap(srv.pid);
        var url_buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{srv.port}) catch unreachable;
        world.stdout_buf.clearRetainingCapacity();
        try std.testing.expectEqual(@as(u8, 0), try run(&.{ "fetch", url }));
        try std.testing.expectEqualStrings(body_text, world.stdout_buf.items);
    }

    {
        const srv = try startResponder();
        defer reap(srv.pid);
        var url_buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{srv.port}) catch unreachable;
        var out_buf: [64]u8 = undefined;
        const outp = std.fmt.bufPrint(&out_buf, "/tmp/utilz-posix-{d}-out", .{linux.getpid()}) catch unreachable;
        try std.testing.expectEqual(@as(u8, 0), try run(&.{ "wget", "-O", outp, url }));
        const fd = try sys.open(outp, .{});
        defer sys.close(fd);
        var buf: [32]u8 = undefined;
        const n = try sys.read(fd, &buf);
        try std.testing.expectEqualStrings(body_text, buf[0..n]);
    }

    {
        const srv = try startResponder();
        defer reap(srv.pid);
        var url_buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://localhost:{d}/", .{srv.port}) catch unreachable;
        world.stdout_buf.clearRetainingCapacity();
        try std.testing.expectEqual(@as(u8, 0), try run(&.{ "fetch", url }));
        try std.testing.expectEqualStrings(body_text, world.stdout_buf.items);
    }

    {
        const srv = try startResponder();
        defer reap(srv.pid);
        var url_buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{srv.port}) catch unreachable;
        const fd = try sys.httpGet(url);
        defer sys.close(fd);
        try std.testing.expectEqual(@as(u32, 200), try sys.httpStatus(fd));
        var buf: [32]u8 = undefined;
        const n = try sys.read(fd, &buf);
        try std.testing.expectEqualStrings(body_text, buf[0..n]);
    }
}

test "wrapper rejects non-loopback and websocket" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    const wrap = try Http.init(std.testing.allocator, world.sysImpl());
    defer wrap.deinit();
    wrap.attach();
    defer sys.detach();
    try std.testing.expectError(error.ENOSYS, sys.httpGet("http://8.8.8.8/"));
    try std.testing.expectError(error.ENOSYS, sys.httpGet("https://example.com"));
    try std.testing.expectError(error.ENOSYS, sys.wsOpen("ws://127.0.0.1"));
    try std.testing.expectError(error.EINVAL, sys.httpGet("http://127.0.0.1/\r\nX: y"));
    try std.testing.expectError(error.EINVAL, sys.httpRequest("GET\rhttp://127.0.0.1/\n\n"));
}
