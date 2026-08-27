//! POSIX spawn/wait against host `/bin`. Missing required binaries fail the suite.

const std = @import("std");
const linux = std.os.linux;
const utilz = @import("utilz");
const sys = utilz.sys;
const posix_mod = utilz.posix;
const registry = utilz.registry;
const Ctx = utilz.Ctx;

const Posix = posix_mod.Posix;

var tmp_seq: u32 = 0;

fn requireHostBins() !void {
    const paths = [_][]const u8{ "/bin/true", "/bin/echo", "/bin/cat", "/usr/bin/env" };
    for (paths) |p| {
        var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (p.len >= buf.len) return error.TestUnexpectedResult;
        @memcpy(buf[0..p.len], p);
        buf[p.len] = 0;
        var st: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, buf[0..p.len :0], 0, linux.STATX.BASIC_STATS, &st);
        const signed: isize = @bitCast(rc);
        if (signed < 0) return error.TestUnexpectedResult;
    }
}

fn nextTmp(buf: []u8, prefix: []const u8) []u8 {
    tmp_seq += 1;
    return std.fmt.bufPrint(buf, "/tmp/utilz-posix-{d}-{d}{s}", .{
        linux.getpid(),
        tmp_seq,
        prefix,
    }) catch unreachable;
}

fn readFd(fd: sys.Fd, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try sys.read(fd, &tmp);
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return buf.toOwnedSlice(allocator);
}

fn runApplet(
    host: *Posix,
    args: []const []const u8,
    stdin_bytes: []const u8,
) !struct { status: u8, stdout: []u8 } {
    host.attach();
    defer sys.detach();

    const in_pipe = try sys.pipe();
    var in_w_open = true;
    errdefer {
        sys.close(in_pipe.r);
        if (in_w_open) sys.close(in_pipe.w);
    }
    if (stdin_bytes.len != 0) try sys.writeAll(in_pipe.w, stdin_bytes);
    sys.close(in_pipe.w);
    in_w_open = false;

    const out_pipe = try sys.pipe();
    var out_w_open = true;
    var out_r_open = true;
    errdefer {
        if (out_r_open) sys.close(out_pipe.r);
        if (out_w_open) sys.close(out_pipe.w);
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: [16][:0]const u8 = undefined;
    if (args.len > store.len) return error.TestUnexpectedResult;
    for (args, 0..) |a, i| store[i] = try arena.dupeZ(u8, a);

    const applet = registry.find(args[0]) orelse return error.TestUnexpectedResult;
    var ctx = Ctx{
        .args = store[0..args.len],
        .gpa = arena,
        .stdin = in_pipe.r,
        .stdout = out_pipe.w,
        .stderr = 2,
    };
    const status = applet.run(&ctx);
    sys.close(out_pipe.w);
    out_w_open = false;
    const stdout = try readFd(out_pipe.r, std.testing.allocator);
    sys.close(out_pipe.r);
    out_r_open = false;
    sys.close(in_pipe.r);
    return .{ .status = status, .stdout = stdout };
}

fn createNoexec(dir_z: [:0]const u8, file_z: [:0]const u8) !void {
    const mrc = linux.mkdir(dir_z, 0o755);
    const msigned: isize = @bitCast(mrc);
    if (msigned < 0) {
        const e: linux.E = @enumFromInt(@as(u16, @intCast(-msigned)));
        if (e != .EXIST) return error.TestUnexpectedResult;
    }
    const fd = linux.open(file_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const fsigned: isize = @bitCast(fd);
    if (fsigned < 0) return error.TestUnexpectedResult;
    _ = linux.close(@intCast(fsigned));
    const crc = linux.chmod(file_z, 0);
    const csigned: isize = @bitCast(crc);
    if (csigned < 0) return error.TestUnexpectedResult;
}

fn cleanupNoexec(dir_z: [:0]const u8, file_z: [:0]const u8) void {
    _ = linux.chmod(file_z, 0o644);
    _ = linux.unlink(file_z);
    _ = linux.rmdir(dir_z);
}

test "required host binaries exist" {
    try requireHostBins();
}

test "spawn /bin/true waitpid 0" {
    try requireHostBins();
    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    host.attach();
    defer sys.detach();
    const pid = try sys.spawn("/bin/true", 0, 1, 2);
    try std.testing.expect(pid > 0);
    try std.testing.expectEqual(@as(i32, 0), try sys.waitpid(pid));
}

test "spawn true PATH search" {
    try requireHostBins();
    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    host.attach();
    defer sys.detach();
    const pid = try sys.spawn("true", 0, 1, 2);
    try std.testing.expectEqual(@as(i32, 0), try sys.waitpid(pid));
}

test "spawn missing path is ENOENT" {
    try requireHostBins();
    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    host.attach();
    defer sys.detach();
    try std.testing.expectError(error.ENOENT, sys.spawn("/no/such", 0, 1, 2));
    try std.testing.expectError(error.ENOENT, sys.spawn("no_such_cmd_on_path", 0, 1, 2));
}

test "slash-path and PATH-search non-executable are EACCES then 126" {
    try requireHostBins();
    const pid_n = linux.getpid();
    var dir_buf: [128]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/utilz-posix-{d}", .{pid_n}) catch unreachable;
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "utilz_noexec_{d}", .{pid_n}) catch unreachable;
    var file_buf: [192]u8 = undefined;
    const file = std.fmt.bufPrintZ(&file_buf, "{s}/{s}", .{ dir, name }) catch unreachable;
    try createNoexec(dir, file);
    defer cleanupNoexec(dir, file);

    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    host.attach();
    defer sys.detach();

    try std.testing.expectError(error.EACCES, sys.spawn(file, 0, 1, 2));

    var path_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&path_buf, "{s}:/usr/bin:/bin", .{dir}) catch unreachable;
    host.search_path = search;
    defer host.search_path = null;
    try std.testing.expectError(error.EACCES, sys.spawn(name, 0, 1, 2));

    sys.detach();
    const env_got = try runApplet(host, &.{ "env", name }, "");
    defer std.testing.allocator.free(env_got.stdout);
    try std.testing.expectEqual(@as(u8, 126), env_got.status);

    const x_got = try runApplet(host, &.{ "xargs", name }, "");
    defer std.testing.allocator.free(x_got.stdout);
    try std.testing.expectEqual(@as(u8, 126), x_got.status);
}

test "xargs /bin/echo from stdin pipe" {
    try requireHostBins();
    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    const got = try runApplet(host, &.{ "xargs", "/bin/echo" }, "a\nb\n");
    defer std.testing.allocator.free(got.stdout);
    try std.testing.expectEqual(@as(u8, 0), got.status);
    try std.testing.expectEqualStrings("a b\n", got.stdout);
}

test "posix usesHostProcessEnviron is true" {
    try requireHostBins();
    var host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    host.attach();
    defer sys.detach();
    try std.testing.expect(sys.usesHostProcessEnviron());
}

test "env /bin/true and env /bin/echo hi" {
    try requireHostBins();
    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    {
        const got = try runApplet(host, &.{ "env", "/bin/true" }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 0), got.status);
    }
    {
        const got = try runApplet(host, &.{ "env", "/bin/echo", "hi" }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 0), got.status);
        try std.testing.expectEqualStrings("hi\n", got.stdout);
    }
}

test "find -exec /bin/true on a host tmpdir" {
    try requireHostBins();
    var dir_buf: [128]u8 = undefined;
    const dir = nextTmp(&dir_buf, "");
    var dir_z_buf: [129]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{dir}) catch unreachable;
    const mrc = linux.mkdir(dir_z, 0o755);
    const msigned: isize = @bitCast(mrc);
    if (msigned < 0) return error.TestUnexpectedResult;
    defer _ = linux.rmdir(dir_z);

    var file_buf: [160]u8 = undefined;
    const file_z = std.fmt.bufPrintZ(&file_buf, "{s}/f", .{dir}) catch unreachable;
    const fd = linux.open(file_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const fsigned: isize = @bitCast(fd);
    if (fsigned < 0) return error.TestUnexpectedResult;
    _ = linux.close(@intCast(fsigned));
    defer _ = linux.unlink(file_z);

    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    const got = try runApplet(host, &.{ "find", dir, "-exec", "/bin/true", "{}", ";" }, "");
    defer std.testing.allocator.free(got.stdout);
    try std.testing.expectEqual(@as(u8, 0), got.status);
}

test "timeout 2 /bin/true and nice /bin/true" {
    try requireHostBins();
    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    {
        const got = try runApplet(host, &.{ "timeout", "2", "/bin/true" }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 0), got.status);
    }
    {
        const got = try runApplet(host, &.{ "nice", "/bin/true" }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 0), got.status);
    }
}

test "env -i and FOO=bar change child envp" {
    try requireHostBins();
    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    {
        const got = try runApplet(host, &.{ "env", "-i", "/usr/bin/env" }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 0), got.status);
        try std.testing.expect(std.mem.indexOf(u8, got.stdout, "PATH=") == null);
        try std.testing.expect(std.mem.indexOf(u8, got.stdout, "HOME=") == null);
    }
    {
        const got = try runApplet(host, &.{ "env", "-i", "FOO=bar", "/usr/bin/env" }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 0), got.status);
        try std.testing.expect(std.mem.indexOf(u8, got.stdout, "FOO=bar\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.stdout, "PATH=") == null);
    }
    {
        const got = try runApplet(host, &.{ "env", "FOO=bar", "/usr/bin/env" }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 0), got.status);
        try std.testing.expect(std.mem.indexOf(u8, got.stdout, "FOO=bar\n") != null);
    }
}

test "env -i PATH overlay is used for execvp search" {
    try requireHostBins();
    const pid_n = linux.getpid();
    var dir_buf: [128]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/utilz-posix-{d}-envpath", .{pid_n}) catch unreachable;
    const mrc = linux.mkdir(dir, 0o755);
    const msigned: isize = @bitCast(mrc);
    if (msigned < 0) {
        const e: linux.E = @enumFromInt(@as(u16, @intCast(-msigned)));
        if (e != .EXIST) return error.TestUnexpectedResult;
    }
    defer _ = linux.rmdir(dir);

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "utilz_envpath_{d}", .{pid_n}) catch unreachable;
    var file_buf: [192]u8 = undefined;
    const file = std.fmt.bufPrintZ(&file_buf, "{s}/{s}", .{ dir, name }) catch unreachable;
    const lrc = linux.symlink("/bin/true", file);
    const lsigned: isize = @bitCast(lrc);
    if (lsigned < 0) return error.TestUnexpectedResult;
    defer _ = linux.unlink(file);

    var path_assign_buf: [192]u8 = undefined;
    const path_assign = std.fmt.bufPrint(&path_assign_buf, "PATH={s}", .{dir}) catch unreachable;

    const host = try Posix.init(std.testing.allocator);
    defer host.deinit();
    {
        const got = try runApplet(host, &.{ "env", "-i", path_assign, name }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 0), got.status);
    }
    {
        const got = try runApplet(host, &.{ "env", "-i", path_assign, "true" }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 127), got.status);
    }
    {
        const got = try runApplet(host, &.{ "env", "-i", "PATH=", name }, "");
        defer std.testing.allocator.free(got.stdout);
        try std.testing.expectEqual(@as(u8, 127), got.status);
    }
}
