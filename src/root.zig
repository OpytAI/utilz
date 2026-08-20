//! utilz — Unix utilities, written for Zig.

const builtin = @import("builtin");

pub const name = "utilz";
pub const version = "0.0.0";

pub const ctx = @import("ctx.zig");
pub const Ctx = ctx.Ctx;
pub const registry = @import("registry.zig");
pub const sys = @import("sys/root.zig");
pub const mem = @import("sys/mem.zig");
pub const posix = if (builtin.os.tag == .freestanding)
    struct {}
else
    @import("sys/posix.zig");
pub const http = if (builtin.os.tag == .freestanding)
    struct {}
else
    @import("sys/http.zig");

pub const engines = struct {
    pub const glob = @import("engines/glob.zig");
    pub const regex = @import("engines/regex.zig");
    pub const datetime = struct {
        pub const calendar = @import("engines/datetime/calendar.zig");
        pub const format = @import("engines/datetime/format.zig");
        pub const parse = @import("engines/datetime/parse.zig");
    };
    pub const sort = struct {
        pub const cmp = @import("engines/sort/cmp.zig");
        pub const key = @import("engines/sort/key.zig");
        pub const engine = @import("engines/sort/engine.zig");
    };
    pub const diffcore = @import("engines/diffcore.zig");
    pub const magic = @import("engines/magic.zig");
    pub const hash = @import("engines/hash.zig");
    pub const codec = @import("engines/codec.zig");
    pub const awklang = @import("engines/awklang/interp.zig");
    pub const jqlang = @import("engines/jqlang/eval.zig");
    pub const sedlang = @import("engines/sedlang/sed.zig");
    pub const gzip = @import("engines/compress/gzcli.zig");
    pub const bzip2 = @import("engines/compress/bzip2.zig");
    pub const tarx = @import("engines/archive/tarx.zig");
    pub const zipwriter = @import("engines/archive/zipwriter.zig");
};

pub const core = struct {
    pub const civil = @import("core/civil.zig");
    pub const fmtnum = @import("core/fmtnum.zig");
    pub const cli = @import("core/cli.zig");
    pub const help = @import("core/help.zig");
    pub const fmt_min = @import("core/fmt_min.zig");
    pub const textio = @import("core/textio.zig");
    pub const fsutil = @import("core/fsutil.zig");
};

test {
    _ = ctx;
    _ = registry;
    _ = sys;
    _ = mem;
    _ = engines.glob;
    _ = engines.regex;
    _ = engines.datetime.calendar;
    _ = engines.sort.cmp;
    _ = engines.sort.key;
    _ = engines.diffcore;
    _ = engines.magic;
    _ = engines.hash;
    _ = engines.codec;
    _ = core.civil;
    _ = core.fmtnum;
}

// Keep posix off the freestanding import graph.
comptime {
    _ = builtin;
}
