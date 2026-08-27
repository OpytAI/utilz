//! Applet-facing syscall facade. Free functions delegate to the attached `Impl`.

const std = @import("std");
const errno = @import("errno.zig");
const types = @import("types.zig");

pub const Errno = errno.Errno;
pub const Error = errno.Error;
pub const fromErrno = errno.fromErrno;
pub const toErrno = errno.toErrno;

pub const Fd = types.Fd;
pub const Pid = types.Pid;
pub const Whence = types.Whence;
pub const Stat = types.Stat;
pub const O = types.O;
pub const Times = types.Times;
pub const Sig = types.Sig;
pub const Disp = types.Disp;
pub const PollFd = types.PollFd;
pub const Pipe = types.Pipe;

pub const STDIN: Fd = 0;
pub const STDOUT: Fd = 1;
pub const STDERR: Fd = 2;

pub const VTable = struct {
    init: *const fn (ptr: *anyopaque) void,
    exit: *const fn (ptr: *anyopaque, code: u8) noreturn,
    argsAlloc: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) Error![]const [:0]const u8,
    open: *const fn (ptr: *anyopaque, path: []const u8, flags: O) Error!Fd,
    read: *const fn (ptr: *anyopaque, fd: Fd, buf: []u8) Error!usize,
    writeAll: *const fn (ptr: *anyopaque, fd: Fd, bytes: []const u8) Error!void,
    close: *const fn (ptr: *anyopaque, fd: Fd) void,
    lseek: *const fn (ptr: *anyopaque, fd: Fd, off: i64, whence: Whence) Error!u64,
    stat: *const fn (ptr: *anyopaque, path: []const u8) Error!Stat,
    lstat: *const fn (ptr: *anyopaque, path: []const u8) Error!Stat,
    readlink: *const fn (ptr: *anyopaque, path: []const u8, buf: []u8) Error!usize,
    symlink: *const fn (ptr: *anyopaque, target: []const u8, link_path: []const u8) Error!void,
    link: *const fn (ptr: *anyopaque, target: []const u8, link_path: []const u8) Error!void,
    unlink: *const fn (ptr: *anyopaque, path: []const u8) Error!void,
    mkdir: *const fn (ptr: *anyopaque, path: []const u8) Error!void,
    readdir: *const fn (ptr: *anyopaque, path: []const u8, buf: []u8) Error!usize,
    rename: *const fn (ptr: *anyopaque, old: []const u8, new: []const u8) Error!void,
    chmod: *const fn (ptr: *anyopaque, path: []const u8, mode: u32) Error!void,
    utimes: *const fn (ptr: *anyopaque, path: []const u8, times: ?Times) Error!void,
    ftruncate: *const fn (ptr: *anyopaque, fd: Fd, len: u64) Error!void,
    chdir: *const fn (ptr: *anyopaque, path: []const u8) Error!void,
    getcwd: *const fn (ptr: *anyopaque, buf: []u8) Error!usize,
    pipe: *const fn (ptr: *anyopaque) Error!Pipe,
    spawn: *const fn (ptr: *anyopaque, argv_blob: []const u8, stdin: Fd, stdout: Fd, stderr: Fd) Error!Pid,
    waitpid: *const fn (ptr: *anyopaque, pid: Pid) Error!i32,
    waitpidNohang: *const fn (ptr: *anyopaque, pid: Pid) Error!?i32,
    kill: *const fn (ptr: *anyopaque, pid: Pid, sig: Sig) Error!void,
    getpid: *const fn (ptr: *anyopaque) Pid,
    nice: *const fn (ptr: *anyopaque, inc: i32) Error!i32,
    sigdisp: *const fn (ptr: *anyopaque, sig: Sig, disp: Disp) Error!void,
    isatty: *const fn (ptr: *anyopaque, fd: Fd) bool,
    timeRealtimeMs: *const fn (ptr: *anyopaque) Error!i64,
    timeMonotonicMs: *const fn (ptr: *anyopaque) Error!i64,
    sleepMs: *const fn (ptr: *anyopaque, ms: i32) void,
    randomBytes: *const fn (ptr: *anyopaque, buf: []u8) Error!void,
    httpGet: *const fn (ptr: *anyopaque, url: []const u8) Error!Fd,
    httpRequest: *const fn (ptr: *anyopaque, blob: []const u8) Error!Fd,
    httpStatus: *const fn (ptr: *anyopaque, fd: Fd) Error!u32,
    wsOpen: *const fn (ptr: *anyopaque, url: []const u8) Error!Fd,
    poll: *const fn (ptr: *anyopaque, fds: []PollFd, timeout_ms: i32) Error!usize,
    usesHostProcessEnviron: *const fn (ptr: *anyopaque) bool,
};

/// Attachable implementation behind the `sys` free functions.
pub const Impl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
};

var current: ?*Impl = null;

/// Only the outermost embedder calls attach/detach. Same-impl attach is a
/// no-op and is not refcounted: an inner detach would drop the outer attach.
pub fn tryAttach(impl: *Impl) error{NestedImpl}!void {
    if (current) |cur| {
        if (cur != impl) return error.NestedImpl;
        return;
    }
    current = impl;
}

pub fn attach(impl: *Impl) void {
    tryAttach(impl) catch @panic("utilz: nested sys.Impl attach");
}

pub fn detach() void {
    current = null;
}

pub fn attached() ?*Impl {
    return current;
}

pub fn tryRequire() error{NotAttached}!*Impl {
    return current orelse error.NotAttached;
}

fn require() *Impl {
    return tryRequire() catch @panic("utilz: sys used without attach");
}

pub fn init() void {
    const impl = require();
    impl.vtable.init(impl.ptr);
}

pub fn exit(code: u8) noreturn {
    const impl = require();
    impl.vtable.exit(impl.ptr, code);
}

pub fn argsAlloc(gpa: std.mem.Allocator) Error![]const [:0]const u8 {
    const impl = require();
    return impl.vtable.argsAlloc(impl.ptr, gpa);
}

pub fn open(path: []const u8, flags: O) Error!Fd {
    const impl = require();
    return impl.vtable.open(impl.ptr, path, flags);
}

pub fn read(fd: Fd, buf: []u8) Error!usize {
    const impl = require();
    return impl.vtable.read(impl.ptr, fd, buf);
}

pub fn writeAll(fd: Fd, bytes: []const u8) Error!void {
    const impl = require();
    return impl.vtable.writeAll(impl.ptr, fd, bytes);
}

pub fn close(fd: Fd) void {
    const impl = require();
    impl.vtable.close(impl.ptr, fd);
}

pub fn lseek(fd: Fd, off: i64, whence: Whence) Error!u64 {
    const impl = require();
    return impl.vtable.lseek(impl.ptr, fd, off, whence);
}

pub fn stat(path: []const u8) Error!Stat {
    const impl = require();
    return impl.vtable.stat(impl.ptr, path);
}

pub fn lstat(path: []const u8) Error!Stat {
    const impl = require();
    return impl.vtable.lstat(impl.ptr, path);
}

pub fn readlink(path: []const u8, buf: []u8) Error!usize {
    const impl = require();
    return impl.vtable.readlink(impl.ptr, path, buf);
}

pub fn symlink(target: []const u8, link_path: []const u8) Error!void {
    const impl = require();
    return impl.vtable.symlink(impl.ptr, target, link_path);
}

pub fn link(target: []const u8, link_path: []const u8) Error!void {
    const impl = require();
    return impl.vtable.link(impl.ptr, target, link_path);
}

pub fn unlink(path: []const u8) Error!void {
    const impl = require();
    return impl.vtable.unlink(impl.ptr, path);
}

pub fn mkdir(path: []const u8) Error!void {
    const impl = require();
    return impl.vtable.mkdir(impl.ptr, path);
}

pub fn readdir(path: []const u8, buf: []u8) Error!usize {
    const impl = require();
    return impl.vtable.readdir(impl.ptr, path, buf);
}

pub fn rename(old: []const u8, new: []const u8) Error!void {
    const impl = require();
    return impl.vtable.rename(impl.ptr, old, new);
}

pub fn chmod(path: []const u8, mode: u32) Error!void {
    const impl = require();
    return impl.vtable.chmod(impl.ptr, path, mode);
}

pub fn utimes(path: []const u8, times: ?Times) Error!void {
    const impl = require();
    return impl.vtable.utimes(impl.ptr, path, times);
}

pub fn ftruncate(fd: Fd, len: u64) Error!void {
    const impl = require();
    return impl.vtable.ftruncate(impl.ptr, fd, len);
}

pub fn chdir(path: []const u8) Error!void {
    const impl = require();
    return impl.vtable.chdir(impl.ptr, path);
}

pub fn getcwd(buf: []u8) Error!usize {
    const impl = require();
    return impl.vtable.getcwd(impl.ptr, buf);
}

pub fn pipe() Error!Pipe {
    const impl = require();
    return impl.vtable.pipe(impl.ptr);
}

pub fn spawn(argv_blob: []const u8, stdin: Fd, stdout: Fd, stderr: Fd) Error!Pid {
    const impl = require();
    return impl.vtable.spawn(impl.ptr, argv_blob, stdin, stdout, stderr);
}

pub fn waitpid(pid: Pid) Error!i32 {
    const impl = require();
    return impl.vtable.waitpid(impl.ptr, pid);
}

pub fn waitpidNohang(pid: Pid) Error!?i32 {
    const impl = require();
    return impl.vtable.waitpidNohang(impl.ptr, pid);
}

pub fn kill(pid: Pid, sig: Sig) Error!void {
    const impl = require();
    return impl.vtable.kill(impl.ptr, pid, sig);
}

pub fn getpid() Pid {
    const impl = require();
    return impl.vtable.getpid(impl.ptr);
}

pub fn nice(inc: i32) Error!i32 {
    const impl = require();
    return impl.vtable.nice(impl.ptr, inc);
}

pub fn sigdisp(sig: Sig, disp: Disp) Error!void {
    const impl = require();
    return impl.vtable.sigdisp(impl.ptr, sig, disp);
}

pub fn isatty(fd: Fd) bool {
    const impl = require();
    return impl.vtable.isatty(impl.ptr, fd);
}

pub fn timeRealtimeMs() Error!i64 {
    const impl = require();
    return impl.vtable.timeRealtimeMs(impl.ptr);
}

pub fn timeMonotonicMs() Error!i64 {
    const impl = require();
    return impl.vtable.timeMonotonicMs(impl.ptr);
}

pub fn sleepMs(ms: i32) void {
    const impl = require();
    impl.vtable.sleepMs(impl.ptr, ms);
}

pub fn randomBytes(buf: []u8) Error!void {
    const impl = require();
    return impl.vtable.randomBytes(impl.ptr, buf);
}

pub fn httpGet(url: []const u8) Error!Fd {
    const impl = require();
    return impl.vtable.httpGet(impl.ptr, url);
}

pub fn httpRequest(blob: []const u8) Error!Fd {
    const impl = require();
    return impl.vtable.httpRequest(impl.ptr, blob);
}

pub fn httpStatus(fd: Fd) Error!u32 {
    const impl = require();
    return impl.vtable.httpStatus(impl.ptr, fd);
}

pub fn wsOpen(url: []const u8) Error!Fd {
    const impl = require();
    return impl.vtable.wsOpen(impl.ptr, url);
}

pub fn poll(fds: []PollFd, timeout_ms: i32) Error!usize {
    const impl = require();
    return impl.vtable.poll(impl.ptr, fds, timeout_ms);
}

pub fn usesHostProcessEnviron() bool {
    const impl = require();
    return impl.vtable.usesHostProcessEnviron(impl.ptr);
}

pub fn strerror(e: Errno) []const u8 {
    return e.strerror();
}
