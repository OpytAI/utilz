//! Zig 0.16 test root. The runner only executes tests imported here.
test {
    _ = @import("root.zig");
    _ = @import("sys_test.zig");
    _ = @import("applets_test.zig");
    _ = @import("engines_test.zig");
}
