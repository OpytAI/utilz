//! Applet goldens over mem `sys.Impl`. Oracle: uutils 0.9.0 behavior.

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

fn expectOut(world: *mem.Mem, args: []const []const u8, want: []const u8) !void {
    const got = try run(world, args);
    defer std.testing.allocator.free(got.stdout);
    defer std.testing.allocator.free(got.stderr);
    try std.testing.expectEqual(@as(u8, 0), got.status);
    try std.testing.expectEqualStrings(want, got.stdout);
}

test "echo cat printf" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    try expectOut(world, &.{ "echo", "hello" }, "hello\n");
    {
        const fd = try sys.open("/tmp/f", .{ .write = true, .create = true, .trunc = true });
        try sys.writeAll(fd, "abc\n");
        sys.close(fd);
        try expectOut(world, &.{ "cat", "/tmp/f" }, "abc\n");
    }
    try expectOut(world, &.{ "printf", "%s", "hi" }, "hi");
}

test "true false basename dirname seq test" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    try std.testing.expectEqual(@as(u8, 0), (try runAndFree(world, &.{"true"})).status);
    try std.testing.expectEqual(@as(u8, 1), (try runAndFree(world, &.{"false"})).status);
    try expectOut(world, &.{ "basename", "/a/b" }, "b\n");
    try expectOut(world, &.{ "dirname", "/a/b" }, "/a\n");
    try expectOut(world, &.{ "seq", "1", "3" }, "1\n2\n3\n");
    try std.testing.expectEqual(@as(u8, 0), (try runAndFree(world, &.{ "test", "a", "=", "a" })).status);
}

test "text filters head wc" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    const fd = try sys.open("/tmp/lines", .{ .write = true, .create = true, .trunc = true });
    try sys.writeAll(fd, "a\nb\nc\n");
    sys.close(fd);
    try expectOut(world, &.{ "head", "-n", "1", "/tmp/lines" }, "a\n");
    try expectOut(world, &.{ "wc", "-l", "/tmp/lines" }, "3 /tmp/lines\n");
}

test "mkdir creates a directory" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    try std.testing.expectEqual(@as(u8, 0), (try runAndFree(world, &.{ "mkdir", "/tmp/d" })).status);
    const st = try sys.stat("/tmp/d");
    try std.testing.expect(st.is_dir);
}

test "grep matches a line" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    const fd = try sys.open("/tmp/g", .{ .write = true, .create = true, .trunc = true });
    try sys.writeAll(fd, "foo\nbar\nbaz\n");
    sys.close(fd);
    try expectOut(world, &.{ "grep", "bar", "/tmp/g" }, "bar\n");
}

test "base64 hello" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    const fd = try sys.open("/tmp/h", .{ .write = true, .create = true, .trunc = true });
    try sys.writeAll(fd, "hello");
    sys.close(fd);
    try expectOut(world, &.{ "base64", "/tmp/h" }, "aGVsbG8=\n");
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

test "fetch and net hooks fail closed" {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    try std.testing.expectError(error.ENOSYS, sys.httpGet("https://example.com/"));
    try std.testing.expectError(error.ENOSYS, sys.httpRequest("GET https://example.com/\n\n"));
    try std.testing.expectError(error.ENOSYS, sys.wsOpen("wss://example.com/"));
    const got = try run(world, &.{ "fetch", "https://example.com/" });
    defer std.testing.allocator.free(got.stdout);
    defer std.testing.allocator.free(got.stderr);
    try std.testing.expect(got.status != 0);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "fetch:") != null);
}

const FreeRun = struct { status: u8 };

fn runAndFree(world: *mem.Mem, args: []const []const u8) !FreeRun {
    const got = try run(world, args);
    std.testing.allocator.free(got.stdout);
    std.testing.allocator.free(got.stderr);
    return .{ .status = got.status };
}
