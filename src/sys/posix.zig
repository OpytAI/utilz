//! Host POSIX `sys.Impl` via Linux syscalls. Network calls return `ENOSYS`.

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

pub const Posix = struct {
    allocator: Allocator,
    args: []const [:0]const u8 = &.{},
    owns_args: bool = false,
    iface: sys.Impl = undefined,
    children: std.AutoHashMap(Pid, i32),

    pub fn init(allocator: Allocator) !*Posix {
        const self = try allocator.create(Posix);
        self.* = .{
            .allocator = allocator,
            .children = std.AutoHashMap(Pid, i32).init(allocator),
        };
        self.iface = .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
        return self;
    }

    pub fn deinit(self: *Posix) void {
        if (self.owns_args) self.allocator.free(self.args);
        self.children.deinit();
        self.allocator.destroy(self);
    }

    pub fn sysImpl(self: *Posix) *sys.Impl {
        return &self.iface;
    }

    pub fn attach(self: *Posix) void {
        sys.attach(&self.iface);
    }
};

fn mapE(e: linux.E) Error {
    return switch (e) {
        .SUCCESS => unreachable,
        .NOENT => error.ENOENT,
        .EXIST => error.EEXIST,
        .PERM, .ACCES => error.EACCES,
        .INVAL => error.EINVAL,
        .BADF => error.EBADF,
        .ISDIR => error.EISDIR,
        .NOTDIR => error.ENOTDIR,
        .NOMEM => error.ENOMEM,
        .NOSPC => error.ENOSPC,
        .PIPE => error.EPIPE,
        .AGAIN => error.EAGAIN,
        .SPIPE => error.ESPIPE,
        .SRCH => error.ESRCH,
        .CHILD => error.ECHILD,
        .NAMETOOLONG => error.ENAMETOOLONG,
        .NOTEMPTY => error.ENOTEMPTY,
        .LOOP => error.ELOOP,
        .XDEV => error.EXDEV,
        .INTR => error.EINTR,
        .IO => error.EIO,
        .RANGE => error.ERANGE,
        .NOSYS => error.ENOSYS,
        else => error.EUNKNOWN,
    };
}

fn check(rc: usize) Error!usize {
    const signed: isize = @bitCast(rc);
    if (signed >= 0) return rc;
    const e: linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
    return mapE(e);
}

fn pathZ(path: []const u8, buf: *[std.Io.Dir.max_path_bytes + 1]u8) Error![:0]u8 {
    if (path.len >= buf.len) return error.ENAMETOOLONG;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn toLinuxO(flags: O) linux.O {
    var o: linux.O = .{};
    if (flags.read and flags.write) {
        o.ACCMODE = .RDWR;
    } else if (flags.write or flags.append) {
        o.ACCMODE = .WRONLY;
    } else {
        o.ACCMODE = .RDONLY;
    }
    o.CREAT = flags.create;
    o.TRUNC = flags.trunc;
    o.APPEND = flags.append;
    return o;
}

fn statFromLinux(st: linux.Statx) Stat {
    const mode: u32 = st.mode & 0o7777;
    return .{
        .size = st.size,
        .mode = mode,
        .nlink = st.nlink,
        .atime_ms = st.atime.sec * 1000,
        .mtime_ms = st.mtime.sec * 1000,
        .ctime_ms = st.ctime.sec * 1000,
        .is_dir = linux.S.ISDIR(st.mode),
        .is_symlink = linux.S.ISLNK(st.mode),
    };
}

fn v_init(_: *anyopaque) void {}

fn v_exit(_: *anyopaque, code: u8) noreturn {
    std.process.exit(code);
}

fn v_argsAlloc(ptr: *anyopaque, _: Allocator) Error![]const [:0]const u8 {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    return self.args;
}

fn v_open(_: *anyopaque, path: []const u8, flags: O) Error!Fd {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    const rc = linux.open(z, toLinuxO(flags), 0o666);
    return @intCast(try check(rc));
}

fn v_read(_: *anyopaque, fd: Fd, buf: []u8) Error!usize {
    return try check(linux.read(fd, buf.ptr, buf.len));
}

fn v_writeAll(_: *anyopaque, fd: Fd, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try check(linux.write(fd, bytes[off..].ptr, bytes.len - off));
        if (n == 0) return error.EIO;
        off += n;
    }
}

fn v_close(_: *anyopaque, fd: Fd) void {
    _ = linux.close(fd);
}

fn v_lseek(_: *anyopaque, fd: Fd, off: i64, whence: Whence) Error!u64 {
    const w: usize = switch (whence) {
        .set => 0,
        .cur => 1,
        .end => 2,
    };
    const rc = linux.lseek(fd, off, w);
    return @intCast(try check(rc));
}

fn v_stat(_: *anyopaque, path: []const u8) Error!Stat {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    var st: linux.Statx = undefined;
    _ = try check(linux.statx(linux.AT.FDCWD, z, 0, linux.STATX.BASIC_STATS, &st));
    return statFromLinux(st);
}

fn v_lstat(_: *anyopaque, path: []const u8) Error!Stat {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    var st: linux.Statx = undefined;
    _ = try check(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &st));
    return statFromLinux(st);
}

fn v_readlink(_: *anyopaque, path: []const u8, out: []u8) Error!usize {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    return try check(linux.readlink(z, out.ptr, out.len));
}

fn v_symlink(_: *anyopaque, target: []const u8, link_path: []const u8) Error!void {
    var tb: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    var lb: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const tz = try pathZ(target, &tb);
    const lz = try pathZ(link_path, &lb);
    _ = try check(linux.symlink(tz, lz));
}

fn v_link(_: *anyopaque, target: []const u8, link_path: []const u8) Error!void {
    var tb: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    var lb: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const tz = try pathZ(target, &tb);
    const lz = try pathZ(link_path, &lb);
    _ = try check(linux.link(tz, lz));
}

fn v_unlink(_: *anyopaque, path: []const u8) Error!void {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    const rc = linux.unlink(z);
    const signed: isize = @bitCast(rc);
    if (signed < 0) {
        const e: linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
        if (e == .ISDIR) {
            _ = try check(linux.rmdir(z));
            return;
        }
    }
    _ = try check(rc);
}

fn v_mkdir(_: *anyopaque, path: []const u8) Error!void {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    _ = try check(linux.mkdir(z, 0o755));
}

fn v_readdir(_: *anyopaque, path: []const u8, buf: []u8) Error!usize {
    var pbuf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &pbuf);
    const fd: i32 = @intCast(try check(linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0)));
    defer _ = linux.close(fd);
    var scratch: [8192]u8 = undefined;
    var off: usize = 0;
    while (true) {
        const n = try check(linux.getdents64(fd, &scratch, scratch.len));
        if (n == 0) break;
        var i: usize = 0;
        while (i + @sizeOf(linux.dirent64) <= n) {
            const dent: *align(1) const linux.dirent64 = @ptrCast(scratch[i..].ptr);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&dent.name)), 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                if (off + name.len + 1 > buf.len) return buf.len;
                @memcpy(buf[off..][0..name.len], name);
                buf[off + name.len] = 0;
                off += name.len + 1;
            }
            if (dent.reclen == 0) break;
            i += dent.reclen;
        }
    }
    return off;
}

fn v_rename(_: *anyopaque, old: []const u8, new: []const u8) Error!void {
    var ob: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    var nb: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const oz = try pathZ(old, &ob);
    const nz = try pathZ(new, &nb);
    _ = try check(linux.rename(oz, nz));
}

fn v_chmod(_: *anyopaque, path: []const u8, mode: u32) Error!void {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    _ = try check(linux.fchmodat(linux.AT.FDCWD, z, @intCast(mode)));
}

fn v_utimes(_: *anyopaque, path: []const u8, times: ?Times) Error!void {
    var pbuf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &pbuf);
    const ts: [2]linux.timespec = if (times) |t| .{
        .{ .sec = @divTrunc(t.atime_ms, 1000), .nsec = @intCast(@mod(t.atime_ms, 1000) * 1_000_000) },
        .{ .sec = @divTrunc(t.mtime_ms, 1000), .nsec = @intCast(@mod(t.mtime_ms, 1000) * 1_000_000) },
    } else .{
        linux.UTIME.NOW,
        linux.UTIME.NOW,
    };
    _ = try check(linux.utimensat(linux.AT.FDCWD, z, &ts, 0));
}

fn v_ftruncate(_: *anyopaque, fd: Fd, len: u64) Error!void {
    _ = try check(linux.ftruncate(fd, @intCast(len)));
}

fn v_chdir(_: *anyopaque, path: []const u8) Error!void {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    _ = try check(linux.chdir(z));
}

fn v_getcwd(_: *anyopaque, buf: []u8) Error!usize {
    const rc = try check(linux.getcwd(buf.ptr, buf.len));
    var n = rc;
    if (n > 0 and buf[n - 1] == 0) n -= 1;
    return n;
}

fn v_pipe(_: *anyopaque) Error!Pipe {
    var fds: [2]i32 = undefined;
    _ = try check(linux.pipe2(&fds, .{}));
    return .{ .r = fds[0], .w = fds[1] };
}

fn v_spawn(_: *anyopaque, _: []const u8, _: Fd, _: Fd, _: Fd) Error!Pid {
    return error.ENOSYS;
}

fn v_waitpid(ptr: *anyopaque, pid: Pid) Error!i32 {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (self.children.fetchRemove(pid)) |kv| return kv.value;
    return error.ECHILD;
}

fn v_waitpidNohang(ptr: *anyopaque, pid: Pid) Error!?i32 {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (self.children.fetchRemove(pid)) |kv| return kv.value;
    return null;
}

fn v_kill(_: *anyopaque, pid: Pid, sig: Sig) Error!void {
    const n: linux.SIG = switch (sig) {
        .hup => .HUP,
        .int => .INT,
        .quit => .QUIT,
        .kill => .KILL,
        .term => .TERM,
        .usr1 => .USR1,
        .usr2 => .USR2,
        .cont => .CONT,
        .stop => .STOP,
        .chld => .CHLD,
        .tstp => .TSTP,
    };
    _ = try check(linux.kill(pid, n));
}

fn v_getpid(_: *anyopaque) Pid {
    return @intCast(linux.getpid());
}

fn v_nice(_: *anyopaque, _: i32) Error!i32 {
    return 0;
}

fn v_sigdisp(_: *anyopaque, _: Sig, _: Disp) Error!void {}

fn v_isatty(_: *anyopaque, _: Fd) bool {
    return false;
}

fn v_timeRealtime(_: *anyopaque) Error!i64 {
    var ts: linux.timespec = undefined;
    _ = try check(linux.clock_gettime(linux.CLOCK.REALTIME, &ts));
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn v_timeMono(_: *anyopaque) Error!i64 {
    var ts: linux.timespec = undefined;
    _ = try check(linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts));
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn v_sleep(_: *anyopaque, ms: i32) void {
    if (ms <= 0) return;
    var req = linux.timespec{ .sec = @divTrunc(ms, 1000), .nsec = @mod(ms, 1000) * 1_000_000 };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

fn v_random(_: *anyopaque, buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try check(linux.getrandom(buf[off..].ptr, buf.len - off, 0));
        if (n == 0) return error.EIO;
        off += n;
    }
}

fn v_enosys_fd(_: *anyopaque, _: []const u8) Error!Fd {
    return error.ENOSYS;
}

fn v_enosys_status(_: *anyopaque, _: Fd) Error!u32 {
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
    .httpGet = v_enosys_fd,
    .httpRequest = v_enosys_fd,
    .httpStatus = v_enosys_status,
    .wsOpen = v_enosys_fd,
    .poll = v_poll,
};

comptime {
    if (builtin.os.tag == .freestanding) {
        @compileError("sys/posix.zig is host-only");
    }
}
