const std = @import("std");
const utilz = @import("utilz");

comptime {
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
    try std.testing.expect(utilz.registry.find("wget") == null);
    try std.testing.expect(utilz.registry.find("wscat") == null);
    try std.testing.expect(utilz.registry.find("true") != null);
    try std.testing.expect(utilz.registry.find("echo") != null);
}
