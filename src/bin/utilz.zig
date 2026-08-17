//! Host multicall: `utilz ls .`

const std = @import("std");
const utilz = @import("utilz");

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const host = try utilz.posix.Posix.init(gpa);
    defer host.deinit();
    host.attach();
    defer utilz.sys.detach();

    var it = std.process.Args.Iterator.init(init.minimal.args);
    var argv_store: std.ArrayListUnmanaged([:0]const u8) = .empty;
    while (it.next()) |a| {
        try argv_store.append(gpa, a);
    }
    const argv = argv_store.items;

    if (argv.len == 0) {
        std.debug.print("utilz: missing argv\n", .{});
        std.process.exit(2);
    }

    var name = basenameOf(argv[0]);
    var rest = argv;
    if (std.mem.eql(u8, name, "utilz") or std.mem.eql(u8, name, "utilz.exe")) {
        if (argv.len < 2) {
            std.debug.print("usage: utilz <applet> [args...]\n", .{});
            std.process.exit(2);
        }
        name = basenameOf(argv[1]);
        rest = argv[1..];
    }

    const applet = utilz.registry.find(name) orelse {
        std.debug.print("utilz: applet not found: {s}\n", .{name});
        std.process.exit(127);
    };

    var ctx = utilz.Ctx{
        .args = rest,
        .gpa = gpa,
        .stdin = utilz.sys.STDIN,
        .stdout = utilz.sys.STDOUT,
        .stderr = utilz.sys.STDERR,
    };
    std.process.exit(applet.run(&ctx));
}
