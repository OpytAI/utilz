//! Applet goldens. Argv and expected bytes come from data/goldens/*.

const std = @import("std");
const utilz = @import("utilz");
const sys = utilz.sys;
const mem = utilz.mem;
const registry = utilz.registry;
const Ctx = utilz.Ctx;

const Golden = struct {
    argv_raw: []const u8,
    expected: []const u8,
    fixture_path: ?[]const u8 = null,
    fixture_bytes: []const u8 = "",
};

const goldens = [_]Golden{
    .{
        .argv_raw = @embedFile("goldens/echo_hello/argv.txt"),
        .expected = @embedFile("goldens/echo_hello/expected.txt"),
    },
    .{
        .argv_raw = @embedFile("goldens/printf_hi/argv.txt"),
        .expected = @embedFile("goldens/printf_hi/expected.txt"),
    },
    .{
        .argv_raw = @embedFile("goldens/cat_abc/argv.txt"),
        .expected = @embedFile("goldens/cat_abc/expected.txt"),
        .fixture_path = "/tmp/f",
        .fixture_bytes = "abc\n",
    },
    .{
        .argv_raw = @embedFile("goldens/base64_hello/argv.txt"),
        .expected = @embedFile("goldens/base64_hello/expected.txt"),
        .fixture_path = "/tmp/h",
        .fixture_bytes = "hello",
    },
};

fn parseArgv(raw: []const u8, store: *[8][]const u8) ![]const []const u8 {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, line, ' ');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (n >= store.len) return error.TestUnexpectedResult;
        store[n] = tok;
        n += 1;
    }
    if (n == 0) return error.TestUnexpectedResult;
    return store[0..n];
}

fn run(world: *mem.Mem, args: []const []const u8) !struct { status: u8, stdout: []u8 } {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var zargs: [8][:0]const u8 = undefined;
    for (args, 0..) |a, i| zargs[i] = try arena.dupeZ(u8, a);
    const applet = registry.find(args[0]) orelse return error.TestUnexpectedResult;
    world.stdout_buf.clearRetainingCapacity();
    var ctx = Ctx{
        .args = zargs[0..args.len],
        .gpa = arena,
        .stdin = 0,
        .stdout = 1,
        .stderr = 2,
    };
    const status = applet.run(&ctx);
    return .{
        .status = status,
        .stdout = try std.testing.allocator.dupe(u8, world.stdout_buf.items),
    };
}

fn runGolden(g: Golden) !void {
    const world = try mem.Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    if (g.fixture_path) |path| {
        const fd = try sys.open(path, .{ .write = true, .create = true, .trunc = true });
        try sys.writeAll(fd, g.fixture_bytes);
        sys.close(fd);
    }
    var store: [8][]const u8 = undefined;
    const args = try parseArgv(g.argv_raw, &store);
    const got = try run(world, args);
    defer std.testing.allocator.free(got.stdout);
    try std.testing.expectEqual(@as(u8, 0), got.status);
    try std.testing.expectEqualStrings(g.expected, got.stdout);
}

test "golden echo hello" {
    try runGolden(goldens[0]);
}

test "golden printf hi" {
    try runGolden(goldens[1]);
}

test "golden cat abc" {
    try runGolden(goldens[2]);
}

test "golden base64 hello" {
    try runGolden(goldens[3]);
}
