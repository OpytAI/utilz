const std = @import("std");
const utilz = @import("utilz");

comptime {
    if (utilz.registry.box.len == 0) {
        @compileError("isolated-min roster is empty");
    }
    for (utilz.registry.box) |applet| {
        if (std.mem.eql(u8, applet.name, "wget")) {
            @compileError("isolated-min analyzed wget");
        }
        if (std.mem.eql(u8, applet.name, "wscat")) {
            @compileError("isolated-min analyzed wscat");
        }
    }
}

test "isolated-min roster excludes net applets" {
    try std.testing.expect(utilz.registry.box.len > 0);
    try std.testing.expect(utilz.registry.find("wget") == null);
    try std.testing.expect(utilz.registry.find("wscat") == null);
    try std.testing.expect(utilz.registry.find("true") != null);
    try std.testing.expect(utilz.registry.find("echo") != null);
    for (utilz.registry.box) |applet| {
        try std.testing.expect(!std.mem.eql(u8, applet.name, "wget"));
        try std.testing.expect(!std.mem.eql(u8, applet.name, "wscat"));
    }
}
