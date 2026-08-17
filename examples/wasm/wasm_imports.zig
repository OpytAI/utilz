//! Print import count for a wasm module. Exit 1 if any import exists
//! or a required export is missing.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const path = it.next() orelse {
        std.debug.print("usage: wasm_imports <file.wasm> [required_export...]\n", .{});
        return 2;
    };
    var required: std.ArrayListUnmanaged([]const u8) = .empty;
    defer required.deinit(init.gpa);
    while (it.next()) |name| try required.append(init.gpa, name);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(bytes);
    const n = try countImports(bytes);
    std.debug.print("imports={d} bytes={d}\n", .{ n, bytes.len });
    if (n != 0) return 1;

    for (required.items) |want| {
        if (!try hasFunctionExport(bytes, want)) {
            std.debug.print("missing export {s}\n", .{want});
            return 1;
        }
    }
    return 0;
}

fn readLeb(bytes: []const u8, i: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (i.* >= bytes.len) return error.Truncated;
        const b = bytes[i.*];
        i.* += 1;
        result |= @as(u32, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
        if (shift >= 28) return error.LebTooLong;
    }
}

fn walkSections(bytes: []const u8, id_want: u8) !?[]const u8 {
    if (bytes.len < 8) return error.BadMagic;
    if (!std.mem.eql(u8, bytes[0..4], "\x00asm")) return error.BadMagic;
    var i: usize = 8;
    while (i + 1 < bytes.len) {
        const id = bytes[i];
        i += 1;
        const size = try readLeb(bytes, &i);
        const end = i + size;
        if (end > bytes.len) return error.Truncated;
        if (id == id_want) return bytes[i..end];
        i = end;
    }
    return null;
}

fn countImports(bytes: []const u8) !u32 {
    const payload = try walkSections(bytes, 2) orelse return 0;
    var j: usize = 0;
    return try readLeb(payload, &j);
}

fn hasFunctionExport(bytes: []const u8, want: []const u8) !bool {
    const payload = try walkSections(bytes, 7) orelse return false;
    var j: usize = 0;
    const count = try readLeb(payload, &j);
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        const name_len = try readLeb(payload, &j);
        const name_end = j + name_len;
        if (name_end > payload.len) return error.Truncated;
        const name = payload[j..name_end];
        j = name_end;
        if (j >= payload.len) return error.Truncated;
        const kind = payload[j];
        j += 1;
        _ = try readLeb(payload, &j);
        if (kind == 0x00 and std.mem.eql(u8, name, want)) return true;
    }
    return false;
}


