//! Attach contract tests.

const std = @import("std");
const sys = @import("sys/root.zig");
const mem = @import("sys/mem.zig");
const registry = @import("registry.zig");
const Ctx = @import("ctx.zig").Ctx;

test "attach then sys works" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    try std.testing.expect(sys.attached() == world.sysImpl());
    const fd = try sys.open("/tmp/x", .{ .write = true, .create = true, .trunc = true });
    try sys.writeAll(fd, "ok");
    sys.close(fd);
}

test "sys without attach is NotAttached" {
    sys.detach();
    try std.testing.expectError(error.NotAttached, sys.tryRequire());
}

test "same impl attach is a no-op" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    world.attach();
    try std.testing.expect(sys.attached() == world.sysImpl());
}

test "different impl attach is NestedImpl" {
    const a = try mem.Mem.init(std.testing.allocator);
    defer a.deinit();
    const b = try mem.Mem.init(std.testing.allocator);
    defer b.deinit();
    a.attach();
    defer sys.detach();
    try std.testing.expectError(error.NestedImpl, sys.tryAttach(b.sysImpl()));
    try std.testing.expect(sys.attached() == a.sysImpl());
}

fn nestedHook(world: *mem.Mem, argv: []const []const u8, stdin: sys.Fd, stdout: sys.Fd, stderr: sys.Fd) sys.Error!u8 {
    if (argv.len == 0) return error.EINVAL;
    const base = argv[0];
    const name = if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base[i + 1 ..] else base;
    const applet = registry.find(name) orelse return error.ENOENT;
    var arena_state = std.heap.ArenaAllocator.init(world.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: std.ArrayListUnmanaged([:0]u8) = .empty;
    for (argv) |a| {
        const z = arena.dupeZ(u8, a) catch return error.ENOMEM;
        store.append(arena, z) catch return error.ENOMEM;
    }
    var args: [8][:0]const u8 = undefined;
    const n = @min(store.items.len, args.len);
    for (store.items[0..n], 0..) |s, i| args[i] = s;
    var ctx = Ctx{
        .args = args[0..n],
        .gpa = arena,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
    };
    return applet.run(&ctx);
}

test "nested spawn run reuses attach" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.spawn_hook = nestedHook;
    world.attach();
    defer sys.detach();
    try std.testing.expect(sys.attached() == world.sysImpl());
    const pid = try sys.spawn("echo\x00from-child", 0, 1, 2);
    const status = try sys.waitpid(pid);
    try std.testing.expectEqual(@as(i32, 0), status);
    try std.testing.expect(sys.attached() == world.sysImpl());
    try std.testing.expectEqualStrings("from-child\n", world.stdout_buf.items);
}

const proc = @import("core/proc.zig");

const IntrWait = struct {
    remaining: u32,
    iface: sys.Impl = undefined,

    fn init(remaining: u32) IntrWait {
        return .{ .remaining = remaining };
    }
};

fn iw_init(_: *anyopaque) void {}
fn iw_exit(_: *anyopaque, _: u8) noreturn {
    while (true) {}
}
fn iw_args(_: *anyopaque, _: std.mem.Allocator) sys.Error![]const [:0]const u8 {
    return &.{};
}
fn iw_enosys_fd(_: *anyopaque, _: []const u8, _: sys.O) sys.Error!sys.Fd {
    return error.ENOSYS;
}
fn iw_read(_: *anyopaque, _: sys.Fd, _: []u8) sys.Error!usize {
    return error.ENOSYS;
}
fn iw_write(_: *anyopaque, _: sys.Fd, _: []const u8) sys.Error!void {
    return error.ENOSYS;
}
fn iw_close(_: *anyopaque, _: sys.Fd) void {}
fn iw_lseek(_: *anyopaque, _: sys.Fd, _: i64, _: sys.Whence) sys.Error!u64 {
    return error.ENOSYS;
}
fn iw_stat(_: *anyopaque, _: []const u8) sys.Error!sys.Stat {
    return error.ENOSYS;
}
fn iw_readlink(_: *anyopaque, _: []const u8, _: []u8) sys.Error!usize {
    return error.ENOSYS;
}
fn iw_two_path(_: *anyopaque, _: []const u8, _: []const u8) sys.Error!void {
    return error.ENOSYS;
}
fn iw_unlink(_: *anyopaque, _: []const u8) sys.Error!void {
    return error.ENOSYS;
}
fn iw_mkdir(_: *anyopaque, _: []const u8) sys.Error!void {
    return error.ENOSYS;
}
fn iw_readdir(_: *anyopaque, _: []const u8, _: []u8) sys.Error!usize {
    return error.ENOSYS;
}
fn iw_chmod(_: *anyopaque, _: []const u8, _: u32) sys.Error!void {
    return error.ENOSYS;
}
fn iw_utimes(_: *anyopaque, _: []const u8, _: ?sys.Times) sys.Error!void {
    return error.ENOSYS;
}
fn iw_ftrunc(_: *anyopaque, _: sys.Fd, _: u64) sys.Error!void {
    return error.ENOSYS;
}
fn iw_chdir(_: *anyopaque, _: []const u8) sys.Error!void {
    return error.ENOSYS;
}
fn iw_getcwd(_: *anyopaque, _: []u8) sys.Error!usize {
    return error.ENOSYS;
}
fn iw_pipe(_: *anyopaque) sys.Error!sys.Pipe {
    return error.ENOSYS;
}
fn iw_spawn(_: *anyopaque, _: []const u8, _: sys.Fd, _: sys.Fd, _: sys.Fd) sys.Error!sys.Pid {
    return error.ENOSYS;
}
fn iw_waitpid(ptr: *anyopaque, _: sys.Pid) sys.Error!i32 {
    const self: *IntrWait = @ptrCast(@alignCast(ptr));
    if (self.remaining > 0) {
        self.remaining -= 1;
        return error.EINTR;
    }
    return 0;
}
fn iw_waitpidNohang(_: *anyopaque, _: sys.Pid) sys.Error!?i32 {
    return error.ENOSYS;
}
fn iw_kill(_: *anyopaque, _: sys.Pid, _: sys.Sig) sys.Error!void {
    return error.ENOSYS;
}
fn iw_getpid(_: *anyopaque) sys.Pid {
    return 1;
}
fn iw_nice(_: *anyopaque, _: i32) sys.Error!i32 {
    return error.ENOSYS;
}
fn iw_sigdisp(_: *anyopaque, _: sys.Sig, _: sys.Disp) sys.Error!void {
    return error.ENOSYS;
}
fn iw_isatty(_: *anyopaque, _: sys.Fd) bool {
    return false;
}
fn iw_time(_: *anyopaque) sys.Error!i64 {
    return error.ENOSYS;
}
fn iw_sleep(_: *anyopaque, _: i32) void {}
fn iw_random(_: *anyopaque, _: []u8) sys.Error!void {
    return error.ENOSYS;
}
fn iw_http_fd(_: *anyopaque, _: []const u8) sys.Error!sys.Fd {
    return error.ENOSYS;
}
fn iw_http_status(_: *anyopaque, _: sys.Fd) sys.Error!u32 {
    return error.ENOSYS;
}
fn iw_poll(_: *anyopaque, _: []sys.PollFd, _: i32) sys.Error!usize {
    return error.ENOSYS;
}

const iw_vtable = sys.VTable{
    .init = iw_init,
    .exit = iw_exit,
    .argsAlloc = iw_args,
    .open = iw_enosys_fd,
    .read = iw_read,
    .writeAll = iw_write,
    .close = iw_close,
    .lseek = iw_lseek,
    .stat = iw_stat,
    .lstat = iw_stat,
    .readlink = iw_readlink,
    .symlink = iw_two_path,
    .link = iw_two_path,
    .unlink = iw_unlink,
    .mkdir = iw_mkdir,
    .readdir = iw_readdir,
    .rename = iw_two_path,
    .chmod = iw_chmod,
    .utimes = iw_utimes,
    .ftruncate = iw_ftrunc,
    .chdir = iw_chdir,
    .getcwd = iw_getcwd,
    .pipe = iw_pipe,
    .spawn = iw_spawn,
    .waitpid = iw_waitpid,
    .waitpidNohang = iw_waitpidNohang,
    .kill = iw_kill,
    .getpid = iw_getpid,
    .nice = iw_nice,
    .sigdisp = iw_sigdisp,
    .isatty = iw_isatty,
    .timeRealtimeMs = iw_time,
    .timeMonotonicMs = iw_time,
    .sleepMs = iw_sleep,
    .randomBytes = iw_random,
    .httpGet = iw_http_fd,
    .httpRequest = iw_http_fd,
    .httpStatus = iw_http_status,
    .wsOpen = iw_http_fd,
    .poll = iw_poll,
};

test "waitRetry retries EINTR" {
    var fake = IntrWait.init(2);
    fake.iface = .{ .ptr = @ptrCast(&fake), .vtable = &iw_vtable };
    sys.attach(&fake.iface);
    defer sys.detach();
    try std.testing.expectEqual(@as(i32, 0), try proc.waitRetry(1));
    try std.testing.expectEqual(@as(u32, 0), fake.remaining);
}
