//! Pure-engine vectors.

const std = @import("std");
const glob = @import("engines/glob.zig");
const regex = @import("engines/regex.zig");
const calendar = @import("engines/datetime/calendar.zig");
const civil = @import("core/civil.zig");
const cmp = @import("engines/sort/cmp.zig");
const codec = @import("engines/codec.zig");
const hash = @import("engines/hash.zig");
const bzip2 = @import("engines/compress/bzip2.zig");

test "glob star and class" {
    try std.testing.expect(glob.match("*.txt", "a.txt"));
    try std.testing.expect(!glob.match("*.txt", "a.bin"));
    try std.testing.expect(glob.match("a?c", "abc"));
    try std.testing.expect(glob.match("[a-c]", "b"));
    try std.testing.expect(!glob.match("[a-c]", "d"));
    try std.testing.expect(glob.matchCI("*.TXT", "a.txt"));
}

test "regex literal and digit" {
    var diag = regex.Diag{};
    var re = try regex.compile(std.testing.allocator, "h.llo", .{}, &diag);
    defer re.deinit();
    try std.testing.expect(re.isMatch("hello"));
    try std.testing.expect(re.isMatch("hxllo"));
    try std.testing.expect(!re.isMatch("goodbye"));

    var digits = try regex.compile(std.testing.allocator, "\\d+", .{}, &diag);
    defer digits.deinit();
    try std.testing.expect(digits.isMatch("ab12cd"));
    try std.testing.expect(!digits.isMatch("abcd"));
}

test "civil epoch" {
    try std.testing.expectEqual(@as(i64, 0), civil.daysFromCivil(1970, 1, 1));
    const d = civil.civilFromDays(0);
    try std.testing.expectEqual(@as(i64, 1970), d.year);
    try std.testing.expectEqual(@as(u32, 1), d.month);
    try std.testing.expectEqual(@as(u32, 1), d.day);
}

test "calendar leap" {
    try std.testing.expect(calendar.isLeapYear(2024));
    try std.testing.expect(!calendar.isLeapYear(2023));
    try std.testing.expectEqual(@as(u32, 29), calendar.daysInMonth(2024, 2));
}

test "sort numeric compare" {
    try std.testing.expectEqual(std.math.Order.lt, cmp.numCmp(cmp.parseNum("2"), cmp.parseNum("10")));
    try std.testing.expectEqual(std.math.Order.lt, cmp.versionCmp("1.2", "1.10"));
}

test "codec base64 hello" {
    const enc = try codec.encodeAlloc(std.testing.allocator, .base64, "hello");
    defer std.testing.allocator.free(enc);
    try std.testing.expectEqualStrings("aGVsbG8=", enc);
}

test "hash sm3 abc" {
    var out: [32]u8 = .{0} ** 32;
    hash.Sm3.hash("abc", &out);
    const want = [_]u8{
        0x66, 0xc7, 0xf0, 0xf4, 0x62, 0xee, 0xed, 0xd9,
        0xd1, 0xf2, 0xd4, 0x6b, 0xdc, 0x10, 0xe4, 0xe2,
        0x41, 0x67, 0xc4, 0x87, 0x5c, 0xf2, 0xf7, 0xa2,
        0x29, 0x7d, 0xa0, 0x2b, 0x8f, 0x4b, 0xa8, 0xe0,
    };
    try std.testing.expectEqualSlices(u8, &want, &out);
}

test "bzip2 rejects garbage" {
    try std.testing.expectError(error.BadMagic, bzip2.decompress(std.testing.allocator, "not bz2"));
}

test "bzip2 fixtures" {
    const one_bz = @embedFile("engines/compress/fixtures/one.bz2");
    const one_txt = @embedFile("engines/compress/fixtures/one.txt");
    const one = try bzip2.decompress(std.testing.allocator, one_bz);
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualSlices(u8, one_txt, one);

    const multi_bz = @embedFile("engines/compress/fixtures/multiblock.bz2");
    const multi_txt = @embedFile("engines/compress/fixtures/multiblock.txt");
    const multi = try bzip2.decompress(std.testing.allocator, multi_bz);
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualSlices(u8, multi_txt, multi);
}
