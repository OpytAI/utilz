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
