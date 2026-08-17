//! Freestanding wasm: cat/ls over mem.

const utilz = @import("utilz");
const std = @import("std");

var heap: [256 * 1024]u8 = undefined;
var fba_state: std.heap.FixedBufferAllocator = undefined;
var world_slot: ?*utilz.mem.Mem = null;

fn runNamed(world: *utilz.mem.Mem, args: []const [:0]const u8) i32 {
    const applet = utilz.registry.find(args[0]) orelse return 3;
    world.stdout_buf.clearRetainingCapacity();
    var ctx = utilz.Ctx{
        .args = args,
        .gpa = world.allocator,
        .stdin = 0,
        .stdout = 1,
        .stderr = 2,
    };
    return applet.run(&ctx);
}

export fn utilz_init() i32 {
    fba_state = std.heap.FixedBufferAllocator.init(&heap);
    const world = utilz.mem.Mem.init(fba_state.allocator()) catch return 1;
    world.attach();
    const hello = world.doOpen("/hello.txt", .{ .write = true, .create = true, .trunc = true }) catch return 1;
    world.doWriteAll(hello, "hi\n") catch return 1;
    world.doClose(hello);
    world.doMkdir("/d") catch return 1;
    const a = world.doOpen("/d/a", .{ .write = true, .create = true, .trunc = true }) catch return 1;
    world.doClose(a);
    world_slot = world;
    return 0;
}

export fn utilz_cat() i32 {
    const world = world_slot orelse return 2;
    return runNamed(world, &.{ "cat", "/hello.txt" });
}

export fn utilz_ls() i32 {
    const world = world_slot orelse return 2;
    return runNamed(world, &.{ "ls", "/d" });
}

export fn utilz_stdout_len() u32 {
    const world = world_slot orelse return 0;
    return @intCast(world.stdout_buf.items.len);
}

export fn utilz_stdout_ptr() [*]const u8 {
    const world = world_slot orelse return @ptrFromInt(1);
    return world.stdout_buf.items.ptr;
}
