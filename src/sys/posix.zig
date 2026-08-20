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

const EnvFd = struct {
    name: []u8,
    write: bool,
};

pub const Posix = struct {
    allocator: Allocator,
    args: []const [:0]const u8 = &.{},
    owns_args: bool = false,
    iface: sys.Impl = undefined,
    /// Test-only PATH for execvp search. `/proc/self/environ` does not change after setenv.
    search_path: ?[]const u8 = null,
    /// In-process `/env` tree so `env -i`/`-u` can change child envp without mkdir on the host.
    env_dir: bool = false,
    env_map: std.StringHashMap([]u8),
    env_fds: std.AutoHashMap(Fd, EnvFd),

    pub fn init(allocator: Allocator) !*Posix {
        const self = try allocator.create(Posix);
        self.* = .{
            .allocator = allocator,
            .env_map = std.StringHashMap([]u8).init(allocator),
            .env_fds = std.AutoHashMap(Fd, EnvFd).init(allocator),
        };
        self.iface = .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
        return self;
    }

    pub fn deinit(self: *Posix) void {
        if (self.owns_args) self.allocator.free(self.args);
        var eit = self.env_map.iterator();
        while (eit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.env_map.deinit();
        var fit = self.env_fds.iterator();
        while (fit.next()) |e| {
            self.allocator.free(e.value_ptr.name);
            _ = linux.close(e.key_ptr.*);
        }
        self.env_fds.deinit();
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

fn isEnvDir(path: []const u8) bool {
    return std.mem.eql(u8, path, "/env") or std.mem.eql(u8, path, "/env/");
}

fn envVarName(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "/env/")) return null;
    const n = path["/env/".len..];
    if (n.len == 0 or std.mem.indexOfScalar(u8, n, '/') != null) return null;
    return n;
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, name, '=') != null) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    return true;
}

fn appendEnvMap(list: *std.ArrayListUnmanaged([:0]u8), self: *Posix) Error!void {
    var it = self.env_map.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const value = e.value_ptr.*;
        if (!validEnvName(name)) continue;
        const line_len = name.len + 1 + value.len;
        const line = self.allocator.allocSentinel(u8, line_len, 0) catch return error.ENOMEM;
        @memcpy(line[0..name.len], name);
        line[name.len] = '=';
        @memcpy(line[name.len + 1 ..][0..value.len], value);
        list.append(self.allocator, line) catch {
            self.allocator.free(line);
            return error.ENOMEM;
        };
    }
}

fn upsertEnvMap(self: *Posix, name: []const u8, value: []const u8) Error!void {
    if (self.env_map.getEntry(name)) |e| {
        const val = self.allocator.dupe(u8, value) catch return error.ENOMEM;
        self.allocator.free(e.value_ptr.*);
        e.value_ptr.* = val;
        return;
    }
    const key = self.allocator.dupe(u8, name) catch return error.ENOMEM;
    errdefer self.allocator.free(key);
    const val = self.allocator.dupe(u8, value) catch return error.ENOMEM;
    errdefer self.allocator.free(val);
    self.env_map.put(key, val) catch return error.ENOMEM;
}

fn openEnvFile(self: *Posix, name: []const u8, flags: O) Error!Fd {
    if (!self.env_dir) return error.ENOENT;
    if (!validEnvName(name)) return error.EINVAL;
    const existing = self.env_map.get(name);
    if (!flags.create and existing == null) return error.ENOENT;
    const mfd = linux.memfd_create("env", 1);
    const fd: Fd = @intCast(try check(mfd));
    errdefer _ = linux.close(fd);
    if (existing) |val| {
        if (!flags.trunc) {
            _ = try check(linux.write(fd, val.ptr, val.len));
            _ = linux.lseek(fd, 0, 0);
        }
    }
    const named = self.allocator.dupe(u8, name) catch return error.ENOMEM;
    self.env_fds.put(fd, .{ .name = named, .write = flags.write or flags.trunc or flags.create }) catch {
        self.allocator.free(named);
        return error.ENOMEM;
    };
    return fd;
}

fn closeEnvFd(self: *Posix, fd: Fd, meta: EnvFd) void {
    defer {
        self.allocator.free(meta.name);
        _ = linux.close(fd);
    }
    if (!meta.write) return;
    _ = linux.lseek(fd, 0, 0);
    var buf: [65536]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    const ns: isize = @bitCast(n);
    if (ns < 0) return;
    upsertEnvMap(self, meta.name, buf[0..@intCast(ns)]) catch {};
}

fn v_open(ptr: *anyopaque, path: []const u8, flags: O) Error!Fd {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (envVarName(path)) |name| return openEnvFile(self, name, flags);
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

fn v_close(ptr: *anyopaque, fd: Fd) void {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (self.env_fds.fetchRemove(fd)) |kv| {
        closeEnvFd(self, fd, kv.value);
        return;
    }
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

fn envStat(self: *Posix, path: []const u8) Error!?Stat {
    if (isEnvDir(path)) {
        if (!self.env_dir) return error.ENOENT;
        return .{
            .size = 0,
            .mode = 0o755,
            .nlink = 2,
            .atime_ms = 0,
            .mtime_ms = 0,
            .ctime_ms = 0,
            .is_dir = true,
            .is_symlink = false,
        };
    }
    if (envVarName(path)) |name| {
        if (!self.env_dir) return error.ENOENT;
        const val = self.env_map.get(name) orelse return error.ENOENT;
        return .{
            .size = val.len,
            .mode = 0o644,
            .nlink = 1,
            .atime_ms = 0,
            .mtime_ms = 0,
            .ctime_ms = 0,
            .is_dir = false,
            .is_symlink = false,
        };
    }
    return null;
}

fn v_stat(ptr: *anyopaque, path: []const u8) Error!Stat {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (try envStat(self, path)) |st| return st;
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    var st: linux.Statx = undefined;
    _ = try check(linux.statx(linux.AT.FDCWD, z, 0, linux.STATX.BASIC_STATS, &st));
    return statFromLinux(st);
}

fn v_lstat(ptr: *anyopaque, path: []const u8) Error!Stat {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (try envStat(self, path)) |st| return st;
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

fn v_unlink(ptr: *anyopaque, path: []const u8) Error!void {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (isEnvDir(path)) {
        if (!self.env_dir) return error.ENOENT;
        var old = self.env_map;
        self.env_map = std.StringHashMap([]u8).init(self.allocator);
        var it = old.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        old.deinit();
        self.env_dir = false;
        return;
    }
    if (envVarName(path)) |name| {
        if (!self.env_dir) return error.ENOENT;
        if (self.env_map.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        return;
    }
    var pbuf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &pbuf);
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

fn v_mkdir(ptr: *anyopaque, path: []const u8) Error!void {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (isEnvDir(path)) {
        if (self.env_dir) return error.EEXIST;
        self.env_dir = true;
        return;
    }
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const z = try pathZ(path, &buf);
    _ = try check(linux.mkdir(z, 0o755));
}

fn v_readdir(ptr: *anyopaque, path: []const u8, buf: []u8) Error!usize {
    const self: *Posix = @ptrCast(@alignCast(ptr));
    if (isEnvDir(path)) {
        if (!self.env_dir) return error.ENOENT;
        var off: usize = 0;
        var it = self.env_map.keyIterator();
        while (it.next()) |k| {
            if (off + k.len + 1 > buf.len) return buf.len;
            @memcpy(buf[off..][0..k.len], k.*);
            buf[off + k.len] = 0;
            off += k.len + 1;
        }
        return off;
    }
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

fn errnoFromRc(rc: usize) linux.E {
    const signed: isize = @bitCast(rc);
    return @enumFromInt(@as(u16, @intCast(-signed)));
}

fn readProcEnviron(buf: []u8) Error![]const u8 {
    const fd: i32 = @intCast(try check(linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0)));
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try check(linux.read(fd, buf[off..].ptr, buf.len - off));
        if (n == 0) break;
        off += n;
    }
    return buf[0..off];
}

fn pathFromEnviron(blob: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry, "PATH=")) return entry["PATH=".len..];
    }
    return null;
}

fn splitBlob(blob: []const u8, list: *std.ArrayListUnmanaged([]const u8), allocator: Allocator) Error!void {
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |part| {
        if (part.len == 0) continue;
        list.append(allocator, part) catch return error.ENOMEM;
    }
}

fn joinPath(allocator: Allocator, dir: []const u8, name: []const u8) Error![:0]u8 {
    const d = if (dir.len == 0) "." else dir;
    if (d[d.len - 1] == '/') {
        const buf = allocator.allocSentinel(u8, d.len + name.len, 0) catch return error.ENOMEM;
        @memcpy(buf[0..d.len], d);
        @memcpy(buf[d.len..], name);
        return buf;
    }
    const buf = allocator.allocSentinel(u8, d.len + 1 + name.len, 0) catch return error.ENOMEM;
    @memcpy(buf[0..d.len], d);
    buf[d.len] = '/';
    @memcpy(buf[d.len + 1 ..], name);
    return buf;
}

fn isAccessClass(e: linux.E) bool {
    return switch (e) {
        .ACCES, .PERM, .NOEXEC, .ISDIR, .TXTBSY => true,
        else => false,
    };
}

fn isSearchContinue(e: linux.E) bool {
    return switch (e) {
        .NOENT, .NOTDIR, .ACCES, .PERM, .NOEXEC, .ISDIR => true,
        else => false,
    };
}

fn decodeWait(status: u32) i32 {
    if (linux.W.IFSIGNALED(status)) {
        return 128 + @as(i32, @intCast(@intFromEnum(linux.W.TERMSIG(status))));
    }
    if (linux.W.IFEXITED(status)) {
        return @intCast(linux.W.EXITSTATUS(status));
    }
    return 1;
}

fn childFail(err_w: i32, e: linux.E) noreturn {
    var eno: u32 = @intFromEnum(e);
    _ = linux.write(err_w, std.mem.asBytes(&eno), @sizeOf(u32));
    linux.exit_group(127);
}

fn childDupFd(fd: Fd, err_w: i32) Fd {
    const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 3);
    const signed: isize = @bitCast(rc);
    if (signed < 0) childFail(err_w, errnoFromRc(rc));
    return @intCast(signed);
}

fn childRelocate(fd: Fd, err_w: i32) Fd {
    if (fd < 0) return fd;
    if (fd > 2) return fd;
    return childDupFd(fd, err_w);
}

fn childDup2(old: Fd, new: Fd, err_w: i32) void {
    const rc = linux.dup2(old, new);
    const signed: isize = @bitCast(rc);
    if (signed < 0) childFail(err_w, errnoFromRc(rc));
}

fn childCloseExtra(keep: i32) void {
    const flags = linux.CLOSE_RANGE{ .UNSHARE = false, .CLOEXEC = false };
    var nosys = false;
    if (keep < 3) {
        const cr = linux.close_range(3, -1, flags);
        if (@as(isize, @bitCast(cr)) < 0 and errnoFromRc(cr) == .NOSYS) nosys = true;
    } else {
        if (keep > 3) {
            const cr = linux.close_range(3, keep - 1, flags);
            if (@as(isize, @bitCast(cr)) < 0 and errnoFromRc(cr) == .NOSYS) nosys = true;
        }
        const cr = linux.close_range(keep + 1, -1, flags);
        if (@as(isize, @bitCast(cr)) < 0 and errnoFromRc(cr) == .NOSYS) nosys = true;
    }
    if (nosys) {
        var fd: i32 = 3;
        while (fd < 1024) : (fd += 1) {
            if (fd != keep) _ = linux.close(fd);
        }
    }
}

fn childInstallStdio(in: Fd, out: Fd, err: Fd, err_w: i32) i32 {
    var keep = err_w;
    if (keep >= 0 and keep <= 2) keep = childDupFd(keep, err_w);
    const in_s = childRelocate(in, keep);
    const out_s = childRelocate(out, keep);
    const err_s = childRelocate(err, keep);
    if (in < 0) {
        _ = linux.close(0);
    } else {
        childDup2(in_s, 0, keep);
    }
    if (out < 0) {
        _ = linux.close(1);
    } else {
        childDup2(out_s, 1, keep);
    }
    if (err < 0) {
        _ = linux.close(2);
    } else {
        childDup2(err_s, 2, keep);
    }
    if (in_s > 2 and in_s != keep) _ = linux.close(in_s);
    if (out_s > 2 and out_s != in_s and out_s != keep) _ = linux.close(out_s);
    if (err_s > 2 and err_s != in_s and err_s != out_s and err_s != keep) _ = linux.close(err_s);
    childCloseExtra(keep);
    return keep;
}

fn childExec(
    in: Fd,
    out: Fd,
    err: Fd,
    err_w: i32,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    paths: []const [*:0]const u8,
    search: bool,
) noreturn {
    const keep = childInstallStdio(in, out, err, err_w);
    var seen_access = false;
    var last: linux.E = .NOENT;
    for (paths) |p| {
        const rc = linux.execve(p, argv, envp);
        last = errnoFromRc(rc);
        if (!search) childFail(keep, last);
        if (!isSearchContinue(last)) childFail(keep, last);
        if (isAccessClass(last)) seen_access = true;
    }
    childFail(keep, if (seen_access) linux.E.ACCES else linux.E.NOENT);
}

fn mapExecE(e: linux.E) Error {
    return switch (e) {
        .NOENT => error.ENOENT,
        .ACCES, .PERM, .NOEXEC, .ISDIR, .TXTBSY => error.EACCES,
        else => mapE(e),
    };
}

fn waitPidRetry(pid: linux.pid_t) void {
    var st: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &st, 0);
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            if (errnoFromRc(rc) == .INTR) continue;
            return;
        }
        return;
    }
}

fn v_spawn(ptr: *anyopaque, blob: []const u8, in: Fd, out: Fd, err: Fd) Error!Pid {
    const self: *Posix = @ptrCast(@alignCast(ptr));

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(self.allocator);
    try splitBlob(blob, &args, self.allocator);
    if (args.items.len == 0) return error.EINVAL;

    var raw: [65536]u8 = undefined;
    const env_blob = try readProcEnviron(&raw);

    var env_owned: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (env_owned.items) |s| self.allocator.free(s);
        env_owned.deinit(self.allocator);
    }
    if (self.env_dir) {
        try appendEnvMap(&env_owned, self);
    } else {
        var eit = std.mem.splitScalar(u8, env_blob, 0);
        while (eit.next()) |entry| {
            if (entry.len == 0) continue;
            const z = self.allocator.dupeZ(u8, entry) catch return error.ENOMEM;
            env_owned.append(self.allocator, z) catch {
                self.allocator.free(z);
                return error.ENOMEM;
            };
        }
    }
    const envp_p = self.allocator.allocSentinel(?[*:0]const u8, env_owned.items.len, null) catch return error.ENOMEM;
    defer self.allocator.free(envp_p);
    for (env_owned.items, 0..) |s, i| envp_p[i] = s.ptr;

    var argv_owned: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (argv_owned.items) |s| self.allocator.free(s);
        argv_owned.deinit(self.allocator);
    }
    for (args.items) |a| {
        const z = self.allocator.dupeZ(u8, a) catch return error.ENOMEM;
        argv_owned.append(self.allocator, z) catch {
            self.allocator.free(z);
            return error.ENOMEM;
        };
    }
    const argv_p = self.allocator.allocSentinel(?[*:0]const u8, argv_owned.items.len, null) catch return error.ENOMEM;
    defer self.allocator.free(argv_p);
    for (argv_owned.items, 0..) |s, i| argv_p[i] = s.ptr;

    var paths_owned: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (paths_owned.items) |s| self.allocator.free(s);
        paths_owned.deinit(self.allocator);
    }
    const cmd = args.items[0];
    const search = std.mem.indexOfScalar(u8, cmd, '/') == null;
    if (!search) {
        const z = self.allocator.dupeZ(u8, cmd) catch return error.ENOMEM;
        paths_owned.append(self.allocator, z) catch {
            self.allocator.free(z);
            return error.ENOMEM;
        };
    } else {
        const path_spec: []const u8 = if (self.search_path) |p| p else blk: {
            // Overlay PATH is what `env` just installed; `/proc/self/environ` is the parent image.
            if (self.env_dir) {
                if (self.env_map.get("PATH")) |p| {
                    if (p.len == 0) return error.ENOENT;
                    break :blk p;
                }
                break :blk "/usr/bin:/bin";
            }
            if (pathFromEnviron(env_blob)) |p| {
                if (p.len == 0) return error.ENOENT;
                break :blk p;
            }
            break :blk "/usr/bin:/bin";
        };
        var pit = std.mem.splitScalar(u8, path_spec, ':');
        while (pit.next()) |dir| {
            const z = try joinPath(self.allocator, dir, cmd);
            paths_owned.append(self.allocator, z) catch {
                self.allocator.free(z);
                return error.ENOMEM;
            };
        }
        if (paths_owned.items.len == 0) return error.ENOENT;
    }

    var path_ptrs = self.allocator.alloc([*:0]const u8, paths_owned.items.len) catch return error.ENOMEM;
    defer self.allocator.free(path_ptrs);
    for (paths_owned.items, 0..) |s, i| path_ptrs[i] = s.ptr;

    var errfds: [2]i32 = undefined;
    _ = try check(linux.pipe2(&errfds, .{ .CLOEXEC = true }));
    var close_pipe = true;
    defer if (close_pipe) {
        _ = linux.close(errfds[0]);
        _ = linux.close(errfds[1]);
    };

    const frc = linux.fork();
    const fsigned: isize = @bitCast(frc);
    if (fsigned < 0) return mapE(errnoFromRc(frc));
    if (fsigned == 0) {
        childExec(in, out, err, errfds[1], argv_p.ptr, envp_p.ptr, path_ptrs, search);
    }

    close_pipe = false;
    _ = linux.close(errfds[1]);

    var errno_buf: [4]u8 = undefined;
    var got: usize = 0;
    while (got < errno_buf.len) {
        const n = linux.read(errfds[0], errno_buf[got..].ptr, errno_buf.len - got);
        const ns: isize = @bitCast(n);
        if (ns < 0) {
            if (errnoFromRc(n) == .INTR) continue;
            _ = linux.close(errfds[0]);
            waitPidRetry(@intCast(fsigned));
            return error.EIO;
        }
        if (ns == 0) break;
        got += @intCast(ns);
    }
    _ = linux.close(errfds[0]);

    const cpid: linux.pid_t = @intCast(fsigned);
    if (got == 4) {
        var eno: u32 = 0;
        @memcpy(std.mem.asBytes(&eno), errno_buf[0..4]);
        waitPidRetry(cpid);
        return mapExecE(@enumFromInt(@as(u16, @truncate(eno))));
    }
    if (got != 0) {
        waitPidRetry(cpid);
        return error.EIO;
    }
    return cpid;
}

fn v_waitpid(_: *anyopaque, pid: Pid) Error!i32 {
    var st: u32 = 0;
    _ = try check(linux.waitpid(pid, &st, 0));
    return decodeWait(st);
}

fn v_waitpidNohang(_: *anyopaque, pid: Pid) Error!?i32 {
    var st: u32 = 0;
    const rc = linux.waitpid(pid, &st, linux.W.NOHANG);
    const signed: isize = @bitCast(rc);
    if (signed == 0) return null;
    if (signed < 0) return mapE(errnoFromRc(rc));
    return decodeWait(st);
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
