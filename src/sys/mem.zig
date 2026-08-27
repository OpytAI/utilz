//! In-memory `sys.Impl`: files, fds, env, and an in-process process table.

const std = @import("std");
const sys = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const Error = sys.Error;
pub const Fd = sys.Fd;
pub const Pid = sys.Pid;
pub const O = sys.O;
pub const Stat = sys.Stat;
pub const Times = sys.Times;
pub const Whence = sys.Whence;
pub const Pipe = sys.Pipe;
pub const PollFd = sys.PollFd;
pub const Sig = sys.Sig;
pub const Disp = sys.Disp;

const CAPTURE_FD_BASE: Fd = -1000;
const MEM_CAP: usize = 32 * 1024 * 1024;

pub const SpawnHook = *const fn (*Mem, []const []const u8, Fd, Fd, Fd) Error!u8;

const NodeKind = enum { file, dir, symlink };

const Node = struct {
    kind: NodeKind,
    data: std.ArrayList(u8) = .empty,
    target: []u8 = &.{},
    mode: u32 = 0o644,
    nlink: u32 = 1,
    atime_ms: i64 = 0,
    mtime_ms: i64 = 0,
    ctime_ms: i64 = 0,
    children: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Node, allocator: Allocator) void {
        self.data.deinit(allocator);
        if (self.target.len != 0) allocator.free(self.target);
        var it = self.children.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        self.children.deinit(allocator);
    }
};

const OpenKind = enum { file, pipe_r, pipe_w, stdio_in, stdio_out, stdio_err };

const Open = struct {
    kind: OpenKind,
    path: []u8 = &.{},
    offset: u64 = 0,
    flags: O = .{},
    pipe_id: u32 = 0,
    closed: bool = false,
};

const PipeBuf = struct {
    data: std.ArrayList(u8) = .empty,
    readers: u32 = 1,
    writers: u32 = 1,
    pos: usize = 0,
};

const Proc = struct {
    status: i32 = 0,
    ready: bool = true,
    pgid: Pid = 1,
};

pub const Mem = struct {
    allocator: Allocator,
    nodes: std.StringHashMap(*Node),
    fds: std.AutoHashMap(Fd, Open),
    pipes: std.AutoHashMap(u32, PipeBuf),
    procs: std.AutoHashMap(Pid, Proc),
    next_fd: Fd = 3,
    next_pipe: u32 = 1,
    next_pid: Pid = 2,
    pid: Pid = 1,
    cwd: []u8,
    stdin_buf: std.ArrayList(u8) = .empty,
    stdout_buf: std.ArrayList(u8) = .empty,
    stderr_buf: std.ArrayList(u8) = .empty,
    stdin_pos: usize = 0,
    bytes_used: usize = 0,
    clock_ms: i64 = 0,
    rng: u64 = 0x9e3779b97f4a7c15,
    spawn_hook: ?SpawnHook = null,
    tty: std.AutoHashMap(Fd, void),
    iface: sys.Impl = undefined,
    args: []const [:0]const u8 = &.{},

    pub fn init(allocator: Allocator) !*Mem {
        const self = try allocator.create(Mem);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .nodes = std.StringHashMap(*Node).init(allocator),
            .fds = std.AutoHashMap(Fd, Open).init(allocator),
            .pipes = std.AutoHashMap(u32, PipeBuf).init(allocator),
            .procs = std.AutoHashMap(Pid, Proc).init(allocator),
            .cwd = try allocator.dupe(u8, "/"),
            .tty = std.AutoHashMap(Fd, void).init(allocator),
        };
        errdefer self.deinit();
        try self.putDir("/");
        try self.putDir("/tmp");
        try self.fds.put(0, .{ .kind = .stdio_in });
        try self.fds.put(1, .{ .kind = .stdio_out });
        try self.fds.put(2, .{ .kind = .stdio_err });
        self.iface = .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
        return self;
    }

    pub fn deinit(self: *Mem) void {
        var seen = std.AutoHashMap(*Node, void).init(self.allocator);
        var nit = self.nodes.iterator();
        while (nit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            if (seen.contains(e.value_ptr.*)) continue;
            seen.put(e.value_ptr.*, {}) catch {};
            e.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(e.value_ptr.*);
        }
        seen.deinit();
        self.nodes.deinit();
        var fit = self.fds.iterator();
        while (fit.next()) |e| {
            if (e.value_ptr.path.len != 0) self.allocator.free(e.value_ptr.path);
        }
        self.fds.deinit();
        var pit = self.pipes.iterator();
        while (pit.next()) |e| e.value_ptr.data.deinit(self.allocator);
        self.pipes.deinit();
        self.procs.deinit();
        self.stdin_buf.deinit(self.allocator);
        self.stdout_buf.deinit(self.allocator);
        self.stderr_buf.deinit(self.allocator);
        self.tty.deinit();
        self.allocator.free(self.cwd);
        self.allocator.destroy(self);
    }

    pub fn sysImpl(self: *Mem) *sys.Impl {
        return &self.iface;
    }

    pub fn attach(self: *Mem) void {
        sys.attach(&self.iface);
    }

    pub fn writeStdin(self: *Mem, bytes: []const u8) !void {
        try self.stdin_buf.appendSlice(self.allocator, bytes);
    }

    fn charge(self: *Mem, n: usize) Error!void {
        if (self.bytes_used + n > MEM_CAP) return error.ENOSPC;
        self.bytes_used += n;
    }

    fn putDir(self: *Mem, path: []const u8) !void {
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        const node = self.allocator.create(Node) catch return error.ENOMEM;
        node.* = .{ .kind = .dir, .mode = 0o755 };
        try self.nodes.put(key, node);
        if (!std.mem.eql(u8, path, "/")) {
            self.addChildName(parentOf(path), basename(path)) catch {};
        }
    }

    fn addChildName(self: *Mem, parent: []const u8, name: []const u8) !void {
        const pnode = self.nodes.get(parent) orelse return;
        if (pnode.kind != .dir) return;
        if (pnode.children.contains(name)) return;
        const owned = try self.allocator.dupe(u8, name);
        try pnode.children.put(self.allocator, owned, {});
    }

    fn removeChildName(self: *Mem, parent: []const u8, name: []const u8) void {
        const pnode = self.nodes.get(parent) orelse return;
        if (pnode.children.fetchSwapRemove(name)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn lexical(self: *Mem, path: []const u8) Error![]u8 {
        const abs = if (path.len > 0 and path[0] == '/')
            path
        else blk: {
            if (path.len == 0) break :blk self.cwd;
            if (self.cwd.len == 1 and self.cwd[0] == '/') {
                const tmp = self.allocator.alloc(u8, 1 + path.len) catch return error.ENOMEM;
                tmp[0] = '/';
                @memcpy(tmp[1..], path);
                defer self.allocator.free(tmp);
                return collapse(self.allocator, tmp) catch return error.ENOMEM;
            }
            const tmp = self.allocator.alloc(u8, self.cwd.len + 1 + path.len) catch return error.ENOMEM;
            @memcpy(tmp[0..self.cwd.len], self.cwd);
            tmp[self.cwd.len] = '/';
            @memcpy(tmp[self.cwd.len + 1 ..], path);
            defer self.allocator.free(tmp);
            return collapse(self.allocator, tmp) catch return error.ENOMEM;
        };
        return collapse(self.allocator, abs) catch return error.ENOMEM;
    }

    fn resolve(self: *Mem, path: []const u8, follow_last: bool) Error![]u8 {
        var cur = try self.lexical(path);
        var hops: usize = 0;
        while (hops < 40) : (hops += 1) {
            const node = self.nodes.get(cur) orelse return cur;
            if (node.kind != .symlink) return cur;
            if (!follow_last) return cur;
            const target = node.target;
            const next = if (target.len > 0 and target[0] == '/')
                collapse(self.allocator, target) catch return error.ENOMEM
            else blk: {
                const p = parentOf(cur);
                const tmp = self.allocator.alloc(u8, p.len + 1 + target.len) catch return error.ENOMEM;
                defer self.allocator.free(tmp);
                @memcpy(tmp[0..p.len], p);
                tmp[p.len] = '/';
                @memcpy(tmp[p.len + 1 ..], target);
                break :blk collapse(self.allocator, tmp) catch return error.ENOMEM;
            };
            self.allocator.free(cur);
            cur = next;
        }
        return error.ELOOP;
    }

    fn parentMustExist(self: *Mem, path: []const u8) Error!void {
        const p = parentOf(path);
        const resolved = try self.resolve(p, true);
        defer self.allocator.free(resolved);
        const node = self.nodes.get(resolved) orelse return error.ENOENT;
        if (node.kind != .dir) return error.ENOTDIR;
    }

    fn allocFd(self: *Mem) Error!Fd {
        var fd = self.next_fd;
        while (self.fds.contains(fd) or fd <= CAPTURE_FD_BASE) {
            fd += 1;
            if (fd < 0) fd = 3;
        }
        self.next_fd = fd + 1;
        return fd;
    }

    fn now(self: *Mem) i64 {
        return self.clock_ms;
    }

    pub fn doOpen(self: *Mem, path: []const u8, flags: O) Error!Fd {
        const lex = try self.lexical(path);
        defer self.allocator.free(lex);
        const existing = self.nodes.get(lex);
        if (existing) |node| {
            if (node.kind == .symlink and (flags.read or flags.write or flags.trunc or flags.append)) {
                const resolved = try self.resolve(lex, true);
                defer self.allocator.free(resolved);
                return self.doOpen(resolved, flags);
            }
            if (node.kind == .dir and flags.write) return error.EISDIR;
            if (flags.trunc and node.kind == .file) {
                self.bytes_used -= node.data.items.len;
                node.data.clearRetainingCapacity();
            }
            const fd = try self.allocFd();
            const owned = self.allocator.dupe(u8, lex) catch return error.ENOMEM;
            self.fds.put(fd, .{
                .kind = .file,
                .path = owned,
                .offset = if (flags.append) node.data.items.len else 0,
                .flags = flags,
            }) catch return error.ENOMEM;
            return fd;
        }
        if (!flags.create) return error.ENOENT;
        try self.parentMustExist(lex);
        const node = self.allocator.create(Node) catch return error.ENOMEM;
        node.* = .{
            .kind = .file,
            .mode = 0o644,
            .atime_ms = self.now(),
            .mtime_ms = self.now(),
            .ctime_ms = self.now(),
        };
        const key = self.allocator.dupe(u8, lex) catch return error.ENOMEM;
        self.nodes.put(key, node) catch return error.ENOMEM;
        self.addChildName(parentOf(lex), basename(lex)) catch {};
        const fd = try self.allocFd();
        const owned = self.allocator.dupe(u8, lex) catch return error.ENOMEM;
        self.fds.put(fd, .{
            .kind = .file,
            .path = owned,
            .offset = 0,
            .flags = flags,
        }) catch return error.ENOMEM;
        return fd;
    }

    pub fn doRead(self: *Mem, fd: Fd, buf: []u8) Error!usize {
        const open = self.fds.getPtr(fd) orelse return error.EBADF;
        if (open.closed) return error.EBADF;
        switch (open.kind) {
            .stdio_in => {
                const avail = self.stdin_buf.items.len - self.stdin_pos;
                const n = @min(avail, buf.len);
                @memcpy(buf[0..n], self.stdin_buf.items[self.stdin_pos..][0..n]);
                self.stdin_pos += n;
                return n;
            },
            .stdio_out, .stdio_err => return error.EBADF,
            .pipe_r => {
                const p = self.pipes.getPtr(open.pipe_id) orelse return error.EBADF;
                const avail = p.data.items.len - p.pos;
                if (avail == 0) {
                    if (p.writers == 0) return 0;
                    return error.EAGAIN;
                }
                const n = @min(avail, buf.len);
                @memcpy(buf[0..n], p.data.items[p.pos..][0..n]);
                p.pos += n;
                return n;
            },
            .pipe_w => return error.EBADF,
            .file => {
                const node = self.nodes.get(open.path) orelse return error.ENOENT;
                if (node.kind == .dir) return error.EISDIR;
                if (open.offset >= node.data.items.len) return 0;
                const avail = node.data.items.len - @as(usize, @intCast(open.offset));
                const n = @min(avail, buf.len);
                @memcpy(buf[0..n], node.data.items[@intCast(open.offset)..][0..n]);
                open.offset += n;
                return n;
            },
        }
    }

    pub fn doWriteAll(self: *Mem, fd: Fd, bytes: []const u8) Error!void {
        const open = self.fds.getPtr(fd) orelse return error.EBADF;
        if (open.closed) return error.EBADF;
        switch (open.kind) {
            .stdio_out => self.stdout_buf.appendSlice(self.allocator, bytes) catch return error.ENOMEM,
            .stdio_err => self.stderr_buf.appendSlice(self.allocator, bytes) catch return error.ENOMEM,
            .stdio_in => return error.EBADF,
            .pipe_w => {
                const p = self.pipes.getPtr(open.pipe_id) orelse return error.EBADF;
                if (p.readers == 0) return error.EPIPE;
                p.data.appendSlice(self.allocator, bytes) catch return error.ENOMEM;
            },
            .pipe_r => return error.EBADF,
            .file => {
                if (!open.flags.write and !open.flags.append) return error.EBADF;
                const node = self.nodes.get(open.path) orelse return error.ENOENT;
                if (node.kind != .file) return error.EISDIR;
                if (open.flags.append) open.offset = node.data.items.len;
                const end = open.offset + bytes.len;
                if (end > node.data.items.len) {
                    const extra = end - node.data.items.len;
                    try self.charge(@intCast(extra));
                    node.data.resize(self.allocator, @intCast(end)) catch return error.ENOMEM;
                }
                @memcpy(node.data.items[@intCast(open.offset)..][0..bytes.len], bytes);
                open.offset = end;
                node.mtime_ms = self.now();
            },
        }
    }

    pub fn doClose(self: *Mem, fd: Fd) void {
        if (fd == 0 or fd == 1 or fd == 2) return;
        if (self.fds.fetchRemove(fd)) |kv| {
            const open = kv.value;
            if (open.kind == .pipe_r or open.kind == .pipe_w) {
                if (self.pipes.getPtr(open.pipe_id)) |p| {
                    if (open.kind == .pipe_r and p.readers > 0) p.readers -= 1;
                    if (open.kind == .pipe_w and p.writers > 0) p.writers -= 1;
                    if (p.readers == 0 and p.writers == 0) {
                        p.data.deinit(self.allocator);
                        _ = self.pipes.remove(open.pipe_id);
                    }
                }
            }
            if (open.path.len != 0) self.allocator.free(open.path);
        }
    }

    pub fn doLseek(self: *Mem, fd: Fd, off: i64, whence: Whence) Error!u64 {
        const open = self.fds.getPtr(fd) orelse return error.EBADF;
        if (open.kind != .file) return error.ESPIPE;
        const node = self.nodes.get(open.path) orelse return error.ENOENT;
        const size: i64 = @intCast(node.data.items.len);
        const base: i64 = switch (whence) {
            .set => 0,
            .cur => @intCast(open.offset),
            .end => size,
        };
        const next = base + off;
        if (next < 0) return error.EINVAL;
        open.offset = @intCast(next);
        return open.offset;
    }

    fn statPath(self: *Mem, path: []const u8, follow: bool) Error!Stat {
        const resolved = try self.resolve(path, follow);
        defer self.allocator.free(resolved);
        const node = self.nodes.get(resolved) orelse return error.ENOENT;
        return Stat{
            .size = switch (node.kind) {
                .file => node.data.items.len,
                .symlink => node.target.len,
                .dir => 0,
            },
            .mode = node.mode,
            .nlink = node.nlink,
            .atime_ms = node.atime_ms,
            .mtime_ms = node.mtime_ms,
            .ctime_ms = node.ctime_ms,
            .is_dir = node.kind == .dir,
            .is_symlink = node.kind == .symlink,
        };
    }

    pub fn doStat(self: *Mem, path: []const u8) Error!Stat {
        return self.statPath(path, true);
    }

    pub fn doLstat(self: *Mem, path: []const u8) Error!Stat {
        return self.statPath(path, false);
    }

    pub fn doReadlink(self: *Mem, path: []const u8, buf: []u8) Error!usize {
        const lex = try self.lexical(path);
        defer self.allocator.free(lex);
        const node = self.nodes.get(lex) orelse return error.ENOENT;
        if (node.kind != .symlink) return error.EINVAL;
        const n = @min(buf.len, node.target.len);
        @memcpy(buf[0..n], node.target[0..n]);
        return n;
    }

    pub fn doSymlink(self: *Mem, target: []const u8, link_path: []const u8) Error!void {
        const lex = try self.lexical(link_path);
        defer self.allocator.free(lex);
        if (self.nodes.get(lex) != null) return error.EEXIST;
        try self.parentMustExist(lex);
        const node = self.allocator.create(Node) catch return error.ENOMEM;
        node.* = .{
            .kind = .symlink,
            .mode = 0o777,
            .target = self.allocator.dupe(u8, target) catch return error.ENOMEM,
            .atime_ms = self.now(),
            .mtime_ms = self.now(),
            .ctime_ms = self.now(),
        };
        const key = self.allocator.dupe(u8, lex) catch return error.ENOMEM;
        self.nodes.put(key, node) catch return error.ENOMEM;
        self.addChildName(parentOf(lex), basename(lex)) catch {};
    }

    pub fn doLink(self: *Mem, target: []const u8, link_path: []const u8) Error!void {
        const src = try self.resolve(target, false);
        defer self.allocator.free(src);
        const node = self.nodes.get(src) orelse return error.ENOENT;
        if (node.kind == .dir) return error.EPERM;
        const dst = try self.lexical(link_path);
        defer self.allocator.free(dst);
        if (self.nodes.get(dst) != null) return error.EEXIST;
        try self.parentMustExist(dst);
        node.nlink += 1;
        const key = self.allocator.dupe(u8, dst) catch return error.ENOMEM;
        self.nodes.put(key, node) catch return error.ENOMEM;
        self.addChildName(parentOf(dst), basename(dst)) catch {};
    }

    pub fn doUnlink(self: *Mem, path: []const u8) Error!void {
        const lex = try self.lexical(path);
        defer self.allocator.free(lex);
        const node = self.nodes.get(lex) orelse return error.ENOENT;
        if (node.kind == .dir and node.children.count() != 0) return error.ENOTEMPTY;
        self.removeChildName(parentOf(lex), basename(lex));
        if (self.nodes.fetchRemove(lex)) |kv| {
            self.allocator.free(kv.key);
            if (kv.value.kind == .dir or kv.value.nlink <= 1) {
                if (kv.value.kind == .file) self.bytes_used -= kv.value.data.items.len;
                kv.value.deinit(self.allocator);
                self.allocator.destroy(kv.value);
            } else {
                kv.value.nlink -= 1;
            }
        }
    }

    pub fn doMkdir(self: *Mem, path: []const u8) Error!void {
        const lex = try self.lexical(path);
        defer self.allocator.free(lex);
        if (self.nodes.get(lex) != null) return error.EEXIST;
        try self.parentMustExist(lex);
        const node = self.allocator.create(Node) catch return error.ENOMEM;
        node.* = .{
            .kind = .dir,
            .mode = 0o755,
            .atime_ms = self.now(),
            .mtime_ms = self.now(),
            .ctime_ms = self.now(),
        };
        const key = self.allocator.dupe(u8, lex) catch return error.ENOMEM;
        self.nodes.put(key, node) catch return error.ENOMEM;
        self.addChildName(parentOf(lex), basename(lex)) catch {};
    }

    pub fn doReaddir(self: *Mem, path: []const u8, buf: []u8) Error!usize {
        const resolved = try self.resolve(path, true);
        defer self.allocator.free(resolved);
        const node = self.nodes.get(resolved) orelse return error.ENOENT;
        if (node.kind != .dir) return error.ENOTDIR;
        var off: usize = 0;
        var it = node.children.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (off + name.len + 1 > buf.len) return buf.len;
            @memcpy(buf[off..][0..name.len], name);
            buf[off + name.len] = 0;
            off += name.len + 1;
        }
        return off;
    }

    pub fn doRename(self: *Mem, old: []const u8, new: []const u8) Error!void {
        const src = try self.lexical(old);
        defer self.allocator.free(src);
        const dst = try self.lexical(new);
        defer self.allocator.free(dst);
        if (std.mem.eql(u8, src, dst)) return;
        const node = self.nodes.get(src) orelse return error.ENOENT;
        // POSIX: EINVAL when old is a directory and new is a descendant of old.
        if (node.kind == .dir and dst.len > src.len and std.mem.startsWith(u8, dst, src) and dst[src.len] == '/') {
            return error.EINVAL;
        }
        if (self.nodes.get(dst)) |existing| {
            if (existing == node) return;
            if (existing.kind == .dir and existing.children.count() != 0) return error.ENOTEMPTY;
            try self.doUnlink(dst);
        }
        try self.parentMustExist(dst);

        var moves: std.ArrayListUnmanaged(struct { old_key: []const u8, n: *Node }) = .empty;
        defer moves.deinit(self.allocator);
        var nit = self.nodes.iterator();
        while (nit.next()) |e| {
            const k = e.key_ptr.*;
            if (std.mem.eql(u8, k, src) or (k.len > src.len and std.mem.startsWith(u8, k, src) and k[src.len] == '/')) {
                moves.append(self.allocator, .{ .old_key = k, .n = e.value_ptr.* }) catch return error.ENOMEM;
            }
        }
        for (moves.items) |item| {
            const suffix = item.old_key[src.len..];
            const new_key = self.allocator.alloc(u8, dst.len + suffix.len) catch return error.ENOMEM;
            @memcpy(new_key[0..dst.len], dst);
            if (suffix.len != 0) @memcpy(new_key[dst.len..], suffix);
            if (self.nodes.fetchRemove(item.old_key)) |kv| self.allocator.free(kv.key);
            self.nodes.put(new_key, item.n) catch return error.ENOMEM;
        }

        var fit = self.fds.iterator();
        while (fit.next()) |e| {
            const p = e.value_ptr.path;
            if (p.len == 0) continue;
            if (!(std.mem.eql(u8, p, src) or (p.len > src.len and std.mem.startsWith(u8, p, src) and p[src.len] == '/'))) continue;
            const suffix = p[src.len..];
            const np = self.allocator.alloc(u8, dst.len + suffix.len) catch return error.ENOMEM;
            @memcpy(np[0..dst.len], dst);
            if (suffix.len != 0) @memcpy(np[dst.len..], suffix);
            self.allocator.free(p);
            e.value_ptr.path = np;
        }

        self.removeChildName(parentOf(src), basename(src));
        self.addChildName(parentOf(dst), basename(dst)) catch {};
    }

    pub fn doChmod(self: *Mem, path: []const u8, mode: u32) Error!void {
        const resolved = try self.resolve(path, false);
        defer self.allocator.free(resolved);
        const node = self.nodes.get(resolved) orelse return error.ENOENT;
        node.mode = mode & 0o7777;
    }

    pub fn doUtimes(self: *Mem, path: []const u8, times: ?Times) Error!void {
        const resolved = try self.resolve(path, false);
        defer self.allocator.free(resolved);
        const node = self.nodes.get(resolved) orelse return error.ENOENT;
        if (times) |t| {
            node.atime_ms = t.atime_ms;
            node.mtime_ms = t.mtime_ms;
        } else {
            node.atime_ms = self.now();
            node.mtime_ms = self.now();
        }
    }

    pub fn doFtruncate(self: *Mem, fd: Fd, len: u64) Error!void {
        const open = self.fds.getPtr(fd) orelse return error.EBADF;
        if (open.kind != .file) return error.EINVAL;
        const node = self.nodes.get(open.path) orelse return error.ENOENT;
        const old = node.data.items.len;
        if (len > old) {
            try self.charge(@intCast(len - old));
            node.data.resize(self.allocator, @intCast(len)) catch return error.ENOMEM;
            @memset(node.data.items[old..], 0);
        } else {
            self.bytes_used -= old - @as(usize, @intCast(len));
            node.data.shrinkRetainingCapacity(@intCast(len));
        }
    }

    pub fn doChdir(self: *Mem, path: []const u8) Error!void {
        const resolved = try self.resolve(path, true);
        errdefer self.allocator.free(resolved);
        const node = self.nodes.get(resolved) orelse return error.ENOENT;
        if (node.kind != .dir) return error.ENOTDIR;
        self.allocator.free(self.cwd);
        self.cwd = resolved;
    }

    pub fn doGetcwd(self: *Mem, buf: []u8) Error!usize {
        if (buf.len < self.cwd.len) return error.ERANGE;
        @memcpy(buf[0..self.cwd.len], self.cwd);
        return self.cwd.len;
    }

    pub fn doPipe(self: *Mem) Error!Pipe {
        const id = self.next_pipe;
        self.next_pipe += 1;
        self.pipes.put(id, .{}) catch return error.ENOMEM;
        const r = try self.allocFd();
        const w = try self.allocFd();
        self.fds.put(r, .{ .kind = .pipe_r, .pipe_id = id }) catch return error.ENOMEM;
        self.fds.put(w, .{ .kind = .pipe_w, .pipe_id = id }) catch return error.ENOMEM;
        return .{ .r = r, .w = w };
    }

    pub fn doSpawn(self: *Mem, argv_blob: []const u8, stdin: Fd, stdout: Fd, stderr: Fd) Error!Pid {
        var argv_store: [32][]const u8 = undefined;
        const argv = splitBlob(argv_blob, &argv_store);
        if (argv.len == 0) return error.EINVAL;
        const hook = self.spawn_hook orelse return error.ENOENT;
        const status = try hook(self, argv, stdin, stdout, stderr);
        const pid = self.next_pid;
        self.next_pid += 1;
        self.procs.put(pid, .{ .status = status, .ready = true, .pgid = pid }) catch return error.ENOMEM;
        return pid;
    }

    pub fn doWaitpid(self: *Mem, pid: Pid) Error!i32 {
        if (self.procs.fetchRemove(pid)) |kv| return kv.value.status;
        return error.ECHILD;
    }

    pub fn doWaitpidNohang(self: *Mem, pid: Pid) Error!?i32 {
        if (self.procs.get(pid)) |p| {
            if (!p.ready) return null;
            _ = self.procs.remove(pid);
            return p.status;
        }
        return error.ECHILD;
    }

    pub fn doKill(self: *Mem, pid: Pid, sig: Sig) Error!void {
        _ = sig;
        if (!self.procs.contains(pid) and pid != self.pid) return error.ESRCH;
    }

    pub fn doGetpid(self: *Mem) Pid {
        return self.pid;
    }

    pub fn doNice(_: *Mem, _: i32) Error!i32 {
        return 0;
    }

    pub fn doSigdisp(_: *Mem, _: Sig, _: Disp) Error!void {}

    pub fn doIsatty(self: *Mem, fd: Fd) bool {
        return self.tty.contains(fd);
    }

    pub fn doTime(self: *Mem) Error!i64 {
        return self.clock_ms;
    }

    pub fn doSleep(self: *Mem, ms: i32) void {
        if (ms > 0) self.clock_ms += ms;
    }

    pub fn doRandom(self: *Mem, buf: []u8) Error!void {
        var x = self.rng;
        for (buf) |*b| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            b.* = @truncate(x);
        }
        self.rng = x;
    }
};

fn parentOf(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        if (idx == 0) return "/";
        return path[0..idx];
    }
    return "/";
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

fn collapse(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(allocator);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (stack.items.len > 0) _ = stack.pop();
            continue;
        }
        try stack.append(allocator, c);
    }
    if (stack.items.len == 0) return allocator.dupe(u8, "/");
    var total: usize = 0;
    for (stack.items) |c| total += 1 + c.len;
    const out = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (stack.items) |c| {
        out[off] = '/';
        off += 1;
        @memcpy(out[off..][0..c.len], c);
        off += c.len;
    }
    return out;
}

pub fn splitBlob(blob: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (n >= out.len) break;
        out[n] = part;
        n += 1;
    }
    return out[0..n];
}

fn v_init(_: *anyopaque) void {}

fn v_exit(_: *anyopaque, _: u8) noreturn {
    while (true) {}
}

fn v_argsAlloc(ptr: *anyopaque, _: Allocator) Error![]const [:0]const u8 {
    const self: *Mem = @ptrCast(@alignCast(ptr));
    return self.args;
}

fn v_open(ptr: *anyopaque, path: []const u8, flags: O) Error!Fd {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doOpen(path, flags);
}
fn v_read(ptr: *anyopaque, fd: Fd, buf: []u8) Error!usize {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doRead(fd, buf);
}
fn v_writeAll(ptr: *anyopaque, fd: Fd, bytes: []const u8) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doWriteAll(fd, bytes);
}
fn v_close(ptr: *anyopaque, fd: Fd) void {
    (@as(*Mem, @ptrCast(@alignCast(ptr)))).doClose(fd);
}
fn v_lseek(ptr: *anyopaque, fd: Fd, off: i64, whence: Whence) Error!u64 {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doLseek(fd, off, whence);
}
fn v_stat(ptr: *anyopaque, path: []const u8) Error!Stat {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doStat(path);
}
fn v_lstat(ptr: *anyopaque, path: []const u8) Error!Stat {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doLstat(path);
}
fn v_readlink(ptr: *anyopaque, path: []const u8, buf: []u8) Error!usize {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doReadlink(path, buf);
}
fn v_symlink(ptr: *anyopaque, target: []const u8, link_path: []const u8) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doSymlink(target, link_path);
}
fn v_link(ptr: *anyopaque, target: []const u8, link_path: []const u8) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doLink(target, link_path);
}
fn v_unlink(ptr: *anyopaque, path: []const u8) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doUnlink(path);
}
fn v_mkdir(ptr: *anyopaque, path: []const u8) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doMkdir(path);
}
fn v_readdir(ptr: *anyopaque, path: []const u8, buf: []u8) Error!usize {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doReaddir(path, buf);
}
fn v_rename(ptr: *anyopaque, old: []const u8, new: []const u8) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doRename(old, new);
}
fn v_chmod(ptr: *anyopaque, path: []const u8, mode: u32) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doChmod(path, mode);
}
fn v_utimes(ptr: *anyopaque, path: []const u8, times: ?Times) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doUtimes(path, times);
}
fn v_ftruncate(ptr: *anyopaque, fd: Fd, len: u64) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doFtruncate(fd, len);
}
fn v_chdir(ptr: *anyopaque, path: []const u8) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doChdir(path);
}
fn v_getcwd(ptr: *anyopaque, buf: []u8) Error!usize {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doGetcwd(buf);
}
fn v_pipe(ptr: *anyopaque) Error!Pipe {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doPipe();
}
fn v_spawn(ptr: *anyopaque, blob: []const u8, stdin: Fd, stdout: Fd, stderr: Fd) Error!Pid {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doSpawn(blob, stdin, stdout, stderr);
}
fn v_waitpid(ptr: *anyopaque, pid: Pid) Error!i32 {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doWaitpid(pid);
}
fn v_waitpidNohang(ptr: *anyopaque, pid: Pid) Error!?i32 {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doWaitpidNohang(pid);
}
fn v_kill(ptr: *anyopaque, pid: Pid, sig: Sig) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doKill(pid, sig);
}
fn v_getpid(ptr: *anyopaque) Pid {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doGetpid();
}
fn v_nice(ptr: *anyopaque, inc: i32) Error!i32 {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doNice(inc);
}
fn v_sigdisp(ptr: *anyopaque, sig: Sig, disp: Disp) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doSigdisp(sig, disp);
}
fn v_isatty(ptr: *anyopaque, fd: Fd) bool {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doIsatty(fd);
}
fn v_time(ptr: *anyopaque) Error!i64 {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doTime();
}
fn v_sleep(ptr: *anyopaque, ms: i32) void {
    (@as(*Mem, @ptrCast(@alignCast(ptr)))).doSleep(ms);
}
fn v_random(ptr: *anyopaque, buf: []u8) Error!void {
    return (@as(*Mem, @ptrCast(@alignCast(ptr)))).doRandom(buf);
}
fn v_enosys_fd(_: *anyopaque, _: []const u8) Error!Fd {
    return error.ENOSYS;
}
fn v_enosys_status(_: *anyopaque, _: Fd) Error!u32 {
    return error.ENOSYS;
}
fn v_poll(_: *anyopaque, _: []PollFd, _: i32) Error!usize {
    return error.ENOSYS;
}
fn v_usesHostProcessEnviron(_: *anyopaque) bool {
    return false;
}

const vtable = sys.VTable{
    .init = v_init,
    .exit = v_exit,
    .argsAlloc = v_argsAlloc,
    .open = v_open,
    .read = v_read,
    .writeAll = v_writeAll,
    .close = v_close,
    .lseek = v_lseek,
    .stat = v_stat,
    .lstat = v_lstat,
    .readlink = v_readlink,
    .symlink = v_symlink,
    .link = v_link,
    .unlink = v_unlink,
    .mkdir = v_mkdir,
    .readdir = v_readdir,
    .rename = v_rename,
    .chmod = v_chmod,
    .utimes = v_utimes,
    .ftruncate = v_ftruncate,
    .chdir = v_chdir,
    .getcwd = v_getcwd,
    .pipe = v_pipe,
    .spawn = v_spawn,
    .waitpid = v_waitpid,
    .waitpidNohang = v_waitpidNohang,
    .kill = v_kill,
    .getpid = v_getpid,
    .nice = v_nice,
    .sigdisp = v_sigdisp,
    .isatty = v_isatty,
    .timeRealtimeMs = v_time,
    .timeMonotonicMs = v_time,
    .sleepMs = v_sleep,
    .randomBytes = v_random,
    .httpGet = v_enosys_fd,
    .httpRequest = v_enosys_fd,
    .httpStatus = v_enosys_status,
    .wsOpen = v_enosys_fd,
    .poll = v_poll,
    .usesHostProcessEnviron = v_usesHostProcessEnviron,
};

test "mem open write read" {
    const world = try Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    const fd = try sys.open("/tmp/a", .{ .write = true, .create = true, .trunc = true });
    try sys.writeAll(fd, "hi");
    sys.close(fd);
    const r = try sys.open("/tmp/a", .{ .read = true });
    var buf: [8]u8 = undefined;
    const n = try sys.read(r, &buf);
    try std.testing.expectEqualStrings("hi", buf[0..n]);
    sys.close(r);
}

test "mem rename moves directory children" {
    const world = try Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    try sys.mkdir("/tmp/d");
    const fd = try sys.open("/tmp/d/f", .{ .write = true, .create = true, .trunc = true });
    try sys.writeAll(fd, "x");
    sys.close(fd);
    try sys.rename("/tmp/d", "/tmp/e");
    try std.testing.expectError(error.ENOENT, sys.stat("/tmp/d/f"));
    const st = try sys.stat("/tmp/e/f");
    try std.testing.expectEqual(@as(u64, 1), st.size);
}

test "mem rename rejects destination under source" {
    const world = try Mem.init(std.testing.allocator);
    defer world.deinit();
    world.attach();
    defer sys.detach();
    try sys.mkdir("/tmp/d");
    try sys.mkdir("/tmp/d/sub");
    const fd = try sys.open("/tmp/d/f", .{ .write = true, .create = true, .trunc = true });
    try sys.writeAll(fd, "x");
    sys.close(fd);
    try std.testing.expectError(error.EINVAL, sys.rename("/tmp/d", "/tmp/d/sub"));
    const r = try sys.open("/tmp/d/f", .{ .read = true });
    var buf: [8]u8 = undefined;
    const n = try sys.read(r, &buf);
    try std.testing.expectEqualStrings("x", buf[0..n]);
    sys.close(r);
}
