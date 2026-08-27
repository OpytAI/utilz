//! Registry sweep and fail-closed net hooks. Behavior goldens live in `data/goldens/`.

const std = @import("std");
const sys = @import("sys/root.zig");
const mem = @import("sys/mem.zig");
const registry = @import("registry.zig");
const Ctx = @import("ctx.zig").Ctx;

const Run = struct {
    status: u8,
    stdout: []u8,
    stderr: []u8,
};

fn run(world: *mem.Mem, args: []const []const u8) !Run {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: std.ArrayListUnmanaged([:0]u8) = .empty;
    for (args) |a| {
        try store.append(arena, try arena.dupeZ(u8, a));
    }
    var argv: [16][:0]const u8 = undefined;
    const n = @min(store.items.len, argv.len);
    for (store.items[0..n], 0..) |s, i| argv[i] = s;
    const applet = registry.find(args[0]) orelse return error.TestUnexpectedResult;
    world.stdout_buf.clearRetainingCapacity();
    world.stderr_buf.clearRetainingCapacity();
    var ctx = Ctx{
        .args = argv[0..n],
        .gpa = arena,
        .stdin = 0,
        .stdout = 1,
        .stderr = 2,
    };
    const status = applet.run(&ctx);
    return .{
        .status = status,
        .stdout = try std.testing.allocator.dupe(u8, world.stdout_buf.items),
        .stderr = try std.testing.allocator.dupe(u8, world.stderr_buf.items),
    };
}

test "every landed applet accepts --help or runs" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    for (registry.box) |applet| {
        if (std.mem.eql(u8, applet.name, "yes")) continue;
        if (std.mem.eql(u8, applet.name, "sleep")) continue;
        if (std.mem.eql(u8, applet.name, "[")) continue;
        const got = try run(world, &.{ applet.name, "--help" });
        defer std.testing.allocator.free(got.stdout);
        defer std.testing.allocator.free(got.stderr);
        const needle = if (std.mem.eql(u8, applet.name, "[")) "test" else applet.name;
        if (got.status != 0 or got.stdout.len == 0 or std.mem.indexOf(u8, got.stdout, needle) == null) {
            std.debug.print("help fail {s} status={d} stdout_len={d}\n", .{ applet.name, got.status, got.stdout.len });
            return error.TestUnexpectedResult;
        }
    }
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

test "env FOO=bar cmd does not unlink /env on mem" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.spawn_hook = nestedHook;
    world.attach();
    defer sys.detach();
    try std.testing.expect(!sys.usesHostProcessEnviron());
    try sys.mkdir("/env");
    {
        const fd = try sys.open("/env/PATH", .{ .write = true, .create = true, .trunc = true });
        defer sys.close(fd);
        try sys.writeAll(fd, "/bin");
    }
    const got = try run(world, &.{ "env", "FOO=bar", "true" });
    defer std.testing.allocator.free(got.stdout);
    defer std.testing.allocator.free(got.stderr);
    try std.testing.expectEqual(@as(u8, 0), got.status);
    _ = try sys.stat("/env");
    _ = try sys.stat("/env/PATH");
    _ = try sys.stat("/env/FOO");
}

test "fetch and net hooks fail closed" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    try std.testing.expectError(error.ENOSYS, sys.httpGet("https://example.com/"));
    try std.testing.expectError(error.ENOSYS, sys.httpGet("http://127.0.0.1/"));
    try std.testing.expectError(error.ENOSYS, sys.httpRequest("GET https://example.com/\n\n"));
    try std.testing.expectError(error.ENOSYS, sys.wsOpen("wss://example.com/"));
    const got = try run(world, &.{ "fetch", "https://example.com/" });
    defer std.testing.allocator.free(got.stdout);
    defer std.testing.allocator.free(got.stderr);
    try std.testing.expect(got.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "fetch:") != null);
}
