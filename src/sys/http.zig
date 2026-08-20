//! Opt-in HTTP `sys.Impl` wrapper. Connects only to loopback; body via `inner.pipe()`.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sys = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const Error = sys.Error;
pub const Fd = sys.Fd;
pub const Pid = sys.Pid;
pub const O = sys.O;
pub const Stat = sys.Stat;
pub const Times = sys.Times;
pub const Whence = sys.Whence;
pub const Pipe = sys.Pipe;
pub const PollFd = sys.PollFd;
pub const Sig = sys.Sig;
pub const Disp = sys.Disp;

const BODY_CAP: usize = 64 * 1024;

pub const Http = struct {
    inner: *sys.Impl,
    allocator: Allocator,
    statuses: std.AutoHashMap(Fd, u32),
    iface: sys.Impl = undefined,

    pub fn init(allocator: Allocator, inner: *sys.Impl) !*Http {
        const self = try allocator.create(Http);
        self.* = .{
            .inner = inner,
            .allocator = allocator,
            .statuses = std.AutoHashMap(Fd, u32).init(allocator),
        };
        self.iface = .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
        return self;
    }

    pub fn deinit(self: *Http) void {
        self.statuses.deinit();
        self.allocator.destroy(self);
    }

    pub fn sysImpl(self: *Http) *sys.Impl {
        return &self.iface;
    }

    pub fn attach(self: *Http) void {
        sys.attach(&self.iface);
    }
};

fn innerOf(ptr: *anyopaque) *sys.Impl {
    const self: *Http = @ptrCast(@alignCast(ptr));
    return self.inner;
}

fn hasCtl(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) return true;
    }
    return false;
}

fn isHttpToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c <= 0x20 or c == 0x7f or c == ':') return false;
    }
    return true;
}

fn parseIpv4(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        if (n >= 4) return null;
        if (p.len == 0 or p.len > 3) return null;
        const v = std.fmt.parseInt(u8, p, 10) catch return null;
        parts[n] = v;
        n += 1;
    }
    if (n != 4) return null;
    return (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) | (@as(u32, parts[2]) << 8) | parts[3];
}

const Target = struct {
    host_hdr: []const u8,
    ip: u32,
    port: u16,
    path: []const u8,
};

fn parseHttpUrl(url: []const u8) Error!Target {
    if (!std.mem.startsWith(u8, url, "http://")) return error.ENOSYS;
    const rest = url["http://".len..];
    if (rest.len == 0) return error.ENOSYS;
    if (rest[0] == '[') return error.ENOSYS;

    var hostport = rest;
    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
        hostport = rest[0..i];
        path = rest[i..];
    }
    if (hostport.len == 0) return error.ENOSYS;
    if (hasCtl(hostport) or hasCtl(path)) return error.EINVAL;

    var host = hostport;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |i| {
        host = hostport[0..i];
        if (host.len == 0) return error.ENOSYS;
        port = std.fmt.parseInt(u16, hostport[i + 1 ..], 10) catch return error.ENOSYS;
    }
    if (hasCtl(host)) return error.EINVAL;

    const ip: u32 = if (std.ascii.eqlIgnoreCase(host, "localhost"))
        0x7f000001
    else blk: {
        const parsed = parseIpv4(host) orelse return error.ENOSYS;
        if (parsed >> 24 != 127) return error.ENOSYS;
        break :blk parsed;
    };

    return .{ .host_hdr = hostport, .ip = ip, .port = port, .path = path };
}

fn findHeadersEnd(buf: []const u8) ?usize {
    if (std.mem.indexOf(u8, buf, "\r\n\r\n")) |i| return i + 4;
    if (std.mem.indexOf(u8, buf, "\n\n")) |i| return i + 2;
    return null;
}

fn headerLineEnd(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn parseStatus(head: []const u8) Error!u32 {
    const nl = std.mem.indexOfScalar(u8, head, '\n') orelse return error.EIO;
    const line = headerLineEnd(head[0..nl]);
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next() orelse return error.EIO;
    const code_s = it.next() orelse return error.EIO;
    return std.fmt.parseInt(u32, code_s, 10) catch return error.EIO;
}

fn isChunked(head: []const u8) bool {
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |raw| {
        const line = headerLineEnd(raw);
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "transfer-encoding")) {
            const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
            var parts = std.mem.splitScalar(u8, v, ',');
            while (parts.next()) |p| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, p, " \t"), "chunked")) return true;
            }
        }
    }
    return false;
}

fn contentLength(head: []const u8) ?usize {
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |raw| {
        const line = headerLineEnd(raw);
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) {
            const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
            return std.fmt.parseInt(usize, v, 10) catch null;
        }
    }
    return null;
}

fn sockCheck(rc: usize) Error!usize {
    const signed: isize = @bitCast(rc);
    if (signed >= 0) return rc;
    return error.EIO;
}

fn exchange(allocator: Allocator, target: Target, method: []const u8, extra_headers: []const u8, body: []const u8) Error!struct { status: u32, body: []u8 } {
    if (!isHttpToken(method)) return error.EINVAL;
    const sock_type: u32 = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    const fd_rc = linux.socket(linux.AF.INET, sock_type, 0);
    const fd: i32 = @intCast(try sockCheck(fd_rc));
    errdefer _ = linux.close(fd);

    var tv = linux.timeval{ .sec = 5, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv).ptr, @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv).ptr, @sizeOf(linux.timeval));

    var addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, target.port),
        .addr = std.mem.nativeToBig(u32, target.ip),
    };
    _ = try sockCheck(linux.connect(fd, &addr, @sizeOf(@TypeOf(addr))));

    var req: std.ArrayListUnmanaged(u8) = .empty;
    defer req.deinit(allocator);
    req.appendSlice(allocator, method) catch return error.ENOMEM;
    req.append(allocator, ' ') catch return error.ENOMEM;
    req.appendSlice(allocator, target.path) catch return error.ENOMEM;
    req.appendSlice(allocator, " HTTP/1.1\r\nHost: ") catch return error.ENOMEM;
    req.appendSlice(allocator, target.host_hdr) catch return error.ENOMEM;
    req.appendSlice(allocator, "\r\nConnection: close\r\n") catch return error.ENOMEM;
    if (extra_headers.len != 0) {
        var hit = std.mem.splitScalar(u8, extra_headers, '\n');
        while (hit.next()) |h| {
            const line = headerLineEnd(h);
            if (line.len == 0) continue;
            if (hasCtl(line)) return error.EINVAL;
            req.appendSlice(allocator, line) catch return error.ENOMEM;
            req.appendSlice(allocator, "\r\n") catch return error.ENOMEM;
        }
    }
    if (body.len != 0) {
        req.appendSlice(allocator, "Content-Length: ") catch return error.ENOMEM;
        var digits: [20]u8 = undefined;
        var n: usize = 0;
        var x = body.len;
        if (x == 0) {
            digits[0] = '0';
            n = 1;
        } else {
            while (x != 0) {
                digits[n] = '0' + @as(u8, @intCast(x % 10));
                n += 1;
                x /= 10;
            }
            var a: usize = 0;
            var b = n - 1;
            while (a < b) {
                const t = digits[a];
                digits[a] = digits[b];
                digits[b] = t;
                a += 1;
                b -= 1;
            }
        }
        req.appendSlice(allocator, digits[0..n]) catch return error.ENOMEM;
        req.appendSlice(allocator, "\r\n") catch return error.ENOMEM;
    }
    req.appendSlice(allocator, "\r\n") catch return error.ENOMEM;
    if (body.len != 0) req.appendSlice(allocator, body) catch return error.ENOMEM;

    var off: usize = 0;
    while (off < req.items.len) {
        const n = try sockCheck(linux.write(fd, req.items[off..].ptr, req.items.len - off));
        if (n == 0) return error.EIO;
        off += n;
    }

    var acc: std.ArrayListUnmanaged(u8) = .empty;
    errdefer acc.deinit(allocator);
    var tmp: [2048]u8 = undefined;
    var hdr_end: ?usize = null;
    while (true) {
        if (acc.items.len > BODY_CAP + 8192) return error.EIO;
        const n = try sockCheck(linux.read(fd, &tmp, tmp.len));
        if (n == 0) break;
        acc.appendSlice(allocator, tmp[0..n]) catch return error.ENOMEM;
        hdr_end = findHeadersEnd(acc.items);
        if (hdr_end != null) break;
    }
    const hend = hdr_end orelse return error.EIO;
    const head = acc.items[0..hend];
    if (isChunked(head)) return error.EIO;
    const status = try parseStatus(head);

    var body_got = acc.items[hend..];
    if (contentLength(head)) |need| {
        if (need > BODY_CAP) return error.EIO;
        while (body_got.len < need) {
            const n = try sockCheck(linux.read(fd, &tmp, tmp.len));
            if (n == 0) break;
            acc.appendSlice(allocator, tmp[0..n]) catch return error.ENOMEM;
            body_got = acc.items[hend..];
        }
        if (body_got.len < need) return error.EIO;
        const owned = allocator.dupe(u8, acc.items[hend .. hend + need]) catch return error.ENOMEM;
        acc.deinit(allocator);
        _ = linux.close(fd);
        return .{ .status = status, .body = owned };
    }
    while (true) {
        if (acc.items.len - hend > BODY_CAP) return error.EIO;
        const n = try sockCheck(linux.read(fd, &tmp, tmp.len));
        if (n == 0) break;
        acc.appendSlice(allocator, tmp[0..n]) catch return error.ENOMEM;
    }
    if (acc.items.len - hend > BODY_CAP) return error.EIO;
    const owned = allocator.dupe(u8, acc.items[hend..]) catch return error.ENOMEM;
    acc.deinit(allocator);
    _ = linux.close(fd);
    return .{ .status = status, .body = owned };
}

fn deliver(self: *Http, status: u32, body: []const u8) Error!Fd {
    const pair = try self.inner.vtable.pipe(self.inner.ptr);
    errdefer {
        self.inner.vtable.close(self.inner.ptr, pair.r);
        self.inner.vtable.close(self.inner.ptr, pair.w);
    }
    try self.inner.vtable.writeAll(self.inner.ptr, pair.w, body);
    self.inner.vtable.close(self.inner.ptr, pair.w);
    self.statuses.put(pair.r, status) catch return error.ENOMEM;
    return pair.r;
}

fn doGet(self: *Http, url: []const u8) Error!Fd {
    const target = try parseHttpUrl(url);
    const got = try exchange(self.allocator, target, "GET", "", "");
    defer self.allocator.free(got.body);
    return deliver(self, got.status, got.body);
}

fn doRequest(self: *Http, blob: []const u8) Error!Fd {
    const nl = std.mem.indexOfScalar(u8, blob, '\n') orelse return error.EINVAL;
    const first = headerLineEnd(blob[0..nl]);
    const sp = std.mem.indexOfScalar(u8, first, ' ') orelse return error.EINVAL;
    const method = first[0..sp];
    const url = std.mem.trim(u8, first[sp + 1 ..], " \t");
    if (!isHttpToken(method) or url.len == 0 or hasCtl(url)) return error.EINVAL;
    const rest = blob[nl + 1 ..];
    var headers: []const u8 = "";
    var body: []const u8 = "";
    if (std.mem.indexOf(u8, rest, "\n\n")) |i| {
        headers = rest[0..i];
        body = rest[i + 2 ..];
    } else if (std.mem.indexOf(u8, rest, "\r\n\r\n")) |i| {
        headers = rest[0..i];
        body = rest[i + 4 ..];
    } else {
        headers = rest;
    }
    const target = try parseHttpUrl(url);
    const got = try exchange(self.allocator, target, method, headers, body);
    defer self.allocator.free(got.body);
    return deliver(self, got.status, got.body);
}

fn v_init(ptr: *anyopaque) void {
    const inner = innerOf(ptr);
    inner.vtable.init(inner.ptr);
}
fn v_exit(ptr: *anyopaque, code: u8) noreturn {
    const inner = innerOf(ptr);
    inner.vtable.exit(inner.ptr, code);
}
fn v_argsAlloc(ptr: *anyopaque, gpa: Allocator) Error![]const [:0]const u8 {
    const inner = innerOf(ptr);
    return inner.vtable.argsAlloc(inner.ptr, gpa);
}
fn v_open(ptr: *anyopaque, path: []const u8, flags: O) Error!Fd {
    const inner = innerOf(ptr);
    return inner.vtable.open(inner.ptr, path, flags);
}
fn v_read(ptr: *anyopaque, fd: Fd, buf: []u8) Error!usize {
    const inner = innerOf(ptr);
    return inner.vtable.read(inner.ptr, fd, buf);
}
fn v_writeAll(ptr: *anyopaque, fd: Fd, bytes: []const u8) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.writeAll(inner.ptr, fd, bytes);
}
fn v_close(ptr: *anyopaque, fd: Fd) void {
    const self: *Http = @ptrCast(@alignCast(ptr));
    _ = self.statuses.remove(fd);
    self.inner.vtable.close(self.inner.ptr, fd);
}
fn v_lseek(ptr: *anyopaque, fd: Fd, off: i64, whence: Whence) Error!u64 {
    const inner = innerOf(ptr);
    return inner.vtable.lseek(inner.ptr, fd, off, whence);
}
fn v_stat(ptr: *anyopaque, path: []const u8) Error!Stat {
    const inner = innerOf(ptr);
    return inner.vtable.stat(inner.ptr, path);
}
fn v_lstat(ptr: *anyopaque, path: []const u8) Error!Stat {
    const inner = innerOf(ptr);
    return inner.vtable.lstat(inner.ptr, path);
}
fn v_readlink(ptr: *anyopaque, path: []const u8, buf: []u8) Error!usize {
    const inner = innerOf(ptr);
    return inner.vtable.readlink(inner.ptr, path, buf);
}
fn v_symlink(ptr: *anyopaque, target: []const u8, link_path: []const u8) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.symlink(inner.ptr, target, link_path);
}
fn v_link(ptr: *anyopaque, target: []const u8, link_path: []const u8) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.link(inner.ptr, target, link_path);
}
fn v_unlink(ptr: *anyopaque, path: []const u8) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.unlink(inner.ptr, path);
}
fn v_mkdir(ptr: *anyopaque, path: []const u8) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.mkdir(inner.ptr, path);
}
fn v_readdir(ptr: *anyopaque, path: []const u8, buf: []u8) Error!usize {
    const inner = innerOf(ptr);
    return inner.vtable.readdir(inner.ptr, path, buf);
}
fn v_rename(ptr: *anyopaque, old: []const u8, new: []const u8) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.rename(inner.ptr, old, new);
}
fn v_chmod(ptr: *anyopaque, path: []const u8, mode: u32) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.chmod(inner.ptr, path, mode);
}
fn v_utimes(ptr: *anyopaque, path: []const u8, times: ?Times) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.utimes(inner.ptr, path, times);
}
fn v_ftruncate(ptr: *anyopaque, fd: Fd, len: u64) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.ftruncate(inner.ptr, fd, len);
}
fn v_chdir(ptr: *anyopaque, path: []const u8) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.chdir(inner.ptr, path);
}
fn v_getcwd(ptr: *anyopaque, buf: []u8) Error!usize {
    const inner = innerOf(ptr);
    return inner.vtable.getcwd(inner.ptr, buf);
}
fn v_pipe(ptr: *anyopaque) Error!Pipe {
    const inner = innerOf(ptr);
    return inner.vtable.pipe(inner.ptr);
}
fn v_spawn(ptr: *anyopaque, argv_blob: []const u8, stdin: Fd, stdout: Fd, stderr: Fd) Error!Pid {
    const inner = innerOf(ptr);
    return inner.vtable.spawn(inner.ptr, argv_blob, stdin, stdout, stderr);
}
fn v_waitpid(ptr: *anyopaque, pid: Pid) Error!i32 {
    const inner = innerOf(ptr);
    return inner.vtable.waitpid(inner.ptr, pid);
}
fn v_waitpidNohang(ptr: *anyopaque, pid: Pid) Error!?i32 {
    const inner = innerOf(ptr);
    return inner.vtable.waitpidNohang(inner.ptr, pid);
}
fn v_kill(ptr: *anyopaque, pid: Pid, sig: Sig) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.kill(inner.ptr, pid, sig);
}
fn v_getpid(ptr: *anyopaque) Pid {
    const inner = innerOf(ptr);
    return inner.vtable.getpid(inner.ptr);
}
fn v_nice(ptr: *anyopaque, inc: i32) Error!i32 {
    const inner = innerOf(ptr);
    return inner.vtable.nice(inner.ptr, inc);
}
fn v_sigdisp(ptr: *anyopaque, sig: Sig, disp: Disp) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.sigdisp(inner.ptr, sig, disp);
}
fn v_isatty(ptr: *anyopaque, fd: Fd) bool {
    const inner = innerOf(ptr);
    return inner.vtable.isatty(inner.ptr, fd);
}
fn v_timeRealtime(ptr: *anyopaque) Error!i64 {
    const inner = innerOf(ptr);
    return inner.vtable.timeRealtimeMs(inner.ptr);
}
fn v_timeMono(ptr: *anyopaque) Error!i64 {
    const inner = innerOf(ptr);
    return inner.vtable.timeMonotonicMs(inner.ptr);
}
fn v_sleep(ptr: *anyopaque, ms: i32) void {
    const inner = innerOf(ptr);
    inner.vtable.sleepMs(inner.ptr, ms);
}
fn v_random(ptr: *anyopaque, buf: []u8) Error!void {
    const inner = innerOf(ptr);
    return inner.vtable.randomBytes(inner.ptr, buf);
}
fn v_httpGet(ptr: *anyopaque, url: []const u8) Error!Fd {
    const self: *Http = @ptrCast(@alignCast(ptr));
    return doGet(self, url);
}
fn v_httpRequest(ptr: *anyopaque, blob: []const u8) Error!Fd {
    const self: *Http = @ptrCast(@alignCast(ptr));
    return doRequest(self, blob);
}
fn v_httpStatus(ptr: *anyopaque, fd: Fd) Error!u32 {
    const self: *Http = @ptrCast(@alignCast(ptr));
    return self.statuses.get(fd) orelse error.EBADF;
}
fn v_wsOpen(_: *anyopaque, _: []const u8) Error!Fd {
    return error.ENOSYS;
}
fn v_poll(_: *anyopaque, _: []PollFd, _: i32) Error!usize {
    return error.ENOSYS;
}

const vtable = sys.VTable{
    .init = v_init,
    .exit = v_exit,
    .argsAlloc = v_argsAlloc,
    .open = v_open,
    .read = v_read,
    .writeAll = v_writeAll,
    .close = v_close,
    .lseek = v_lseek,
    .stat = v_stat,
    .lstat = v_lstat,
    .readlink = v_readlink,
    .symlink = v_symlink,
    .link = v_link,
    .unlink = v_unlink,
    .mkdir = v_mkdir,
    .readdir = v_readdir,
    .rename = v_rename,
    .chmod = v_chmod,
    .utimes = v_utimes,
    .ftruncate = v_ftruncate,
    .chdir = v_chdir,
    .getcwd = v_getcwd,
    .pipe = v_pipe,
    .spawn = v_spawn,
    .waitpid = v_waitpid,
    .waitpidNohang = v_waitpidNohang,
    .kill = v_kill,
    .getpid = v_getpid,
    .nice = v_nice,
    .sigdisp = v_sigdisp,
    .isatty = v_isatty,
    .timeRealtimeMs = v_timeRealtime,
    .timeMonotonicMs = v_timeMono,
    .sleepMs = v_sleep,
    .randomBytes = v_random,
    .httpGet = v_httpGet,
    .httpRequest = v_httpRequest,
    .httpStatus = v_httpStatus,
    .wsOpen = v_wsOpen,
    .poll = v_poll,
};

comptime {
    if (builtin.os.tag == .freestanding) {
        @compileError("sys/http.zig is host-only");
    }
}
