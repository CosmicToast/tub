//! Wrapper around UEFI Files.

const std  = @import("std");
const mem  = std.mem;
const uefi = std.os.uefi;

const globals = @import("globals.zig");
const text = @import("text.zig");

const Error = uefi.Error;

const Allocator = std.mem.Allocator;
const File      = uefi.protocol.File;
const Info      = File.Info.File;

const Self = @This();

file: *File,
// what's a bit of a shame is that since I COULD make this be an *Info
// but it makes a few other things a pain
ibuf: []align(8) u8,

// WARN: destroy will close your file; i.e. @This() takes ownership
pub fn create(file: *File, alloc: Allocator) Error!Self {
    const isz  = try file.getInfoSize(.file);
    const ibuf = alloc.alignedAlloc(u8, .@"8", isz)
        catch return Error.OutOfResources;
    _ = try file.getInfo(.file, ibuf);
    return .{ .file = file, .ibuf = ibuf};
}

pub fn fromImage(alloc: Allocator) Error!Self {
    return create(
        globals.sfs.openVolume() catch return error.MediaChanged,
        alloc
    ) catch error.OutOfResources;
}

pub fn destroy(self: *Self, alloc: Allocator) void {
    alloc.free(self.ibuf);
    // if we fail to close it there's not much we can do about it anyway
    self.file.close() catch {};
}

pub fn openUcs2(self: Self, alloc: Allocator, path: [*:0]const u16) Error!Self {
    return create(try self.file.open(path, .read, .{}), alloc);
}

pub fn open(self: Self, alloc: Allocator, path: []const u8) Error!Self {
    const psz  = try text.calcUcs2Len(path);
    const pbuf = alloc.allocSentinel(u16, psz, 0)
        catch return Error.OutOfResources;
    defer alloc.free(pbuf);

    const rsz = try text.utf8ToUcs2(pbuf, path);
    std.debug.assert(rsz == psz);

    return self.openUcs2(alloc, pbuf);
}

pub fn slurp(self: Self, alloc: Allocator) ![]u8 {
    std.debug.assert(!self.info().attribute.directory);
    const esz = self.info().file_size;
    const buf = try alloc.alloc(u8, esz);
    errdefer alloc.free(buf);
    const rsz = try self.file.read(buf);
    std.debug.assert(esz == rsz);
    return buf; // free this yourself
}

pub fn info(self: Self) *const Info {
    return std.mem.bytesAsValue(Info, self.ibuf);
}

pub fn name(self: Self) []const u16 {
    return mem.span(self.info().getFileName());
}

pub fn nameUtf8(self: Self, alloc: Allocator) ![]const u8 {
    const ucs2 = self.name();
    const bsz  = text.calcUtf8Len(ucs2);
    const buf  = alloc.alloc(u8, bsz);
    const rsz  = text.ucs2ToUtf8(buf, ucs2);
    std.debug.assert(rsz == bsz);
    return buf; // free this yourself
}

const Iterator = struct {
    file: *File,
    pat: ?[]const u8,
    buf: []align(8) u8,

    fn destroy(self: *Iterator, alloc: Allocator) void {
        alloc.free(self.buf);
    }

    fn init(self: Self, alloc: Allocator, pat: ?[]const u8) !Iterator {
        std.debug.assert(self.info().attribute.directory);
        var out: Iterator = .{ .file = self.file, .pat = pat, .buf = &.{} };

        try out.reset();
        errdefer out.destroy(alloc);
        while (true) {
            const esz = try out.file.readSize();
            if (esz == 0) break; // done iterating
            if (out.buf.len < esz)
                out.buf = try alloc.realloc(out.buf, esz);
            const rsz = try out.file.read(out.buf);
            std.debug.assert(rsz == esz);
        }
        try out.reset(); // reset iteration
        return out;
    }

    fn reset(self: *Iterator) !void {
        try self.file.setPosition(0);
    }

    // note that the return value is only valid until the next invocation
    pub fn next(self: *Iterator) ?*Info {
        // this generally shouldn't fail unless you pull the device out
        // in which case crashing catastrophically is kind of expected tbh tbh
        const sz = self.file.read(self.buf) catch unreachable;
        if (sz == 0) return null; // done
        if (self.pat) |pat| {
            if (!text.glob(pat, std.mem.span(self.info().getFileName())))
                return @call(.always_tail, next, .{self});
        }
        return self.info();
    }

    fn info(self: *Iterator) *Info {
        return std.mem.bytesAsValue(Info, self.buf);
    }
};

pub fn iterate(self: Self, alloc: Allocator) !Iterator {
    return try Iterator.init(self, alloc, null);
}

pub fn glob(self: Self, pattern: []const u8, alloc: Allocator) !Iterator {
    return try Iterator.init(self, alloc, pattern);
}

pub fn find(self: Self, pattern: []const u8, gpa: Allocator) ![][]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var it = std.mem.splitScalar(
        u8,
        if (pattern[0] == '\\') pattern[1..] else pattern,
        '\\'
    );
    return findParts(self, &it, gpa, alloc);
}

fn findParts(
    self: Self,
    parts: *std.mem.SplitIterator(u8, .scalar),
    gpa: Allocator,
    arena: Allocator) ![][]u8 {
    // collect all matching filenames of this part
    var out = std.ArrayList([]u8).empty; // TODO: estimate? :D
    var it = try self.glob(parts.next() orelse return &.{}, arena);
    while (it.next()) |file| {
        const ucs2 = file.getFileName();
        const ucss = std.mem.span(ucs2);
        const elen = try text.calcUtf8Len(ucss);
        const utf8 = try gpa.alloc(u8, elen);
        const rlen = try text.ucs2ToUtf8(utf8, ucss);
        std.debug.assert(elen == rlen);
        try out.append(gpa, utf8);
    }
    const here = try out.toOwnedSlice(gpa); // NOTE: calls clearAndFree
    if (parts.peek() == null) return here; // TODO: maybe remove directories?
    defer gpa.free(here);

    // there are more parts, so we have to iterate down into each part, joining the paths
    // NOTE: all recursive operations pass arena as gpa, so freeing will be done on find exit
    for (here) |file| {
        var subdir = try self.open(arena, file);
        defer subdir.destroy(arena);
        // since we have more subpaths, we only want directories
        if (!subdir.info().attribute.directory) continue;
        // NOTE: copying parts
        var partsCopy = parts.*;
        const submatches = try findParts(subdir, &partsCopy, arena, arena);
        for (submatches) |subpath| {
            const fullpath = try std.mem.join(gpa, "\\", &.{file, subpath});
            try out.append(gpa, fullpath);
        }
    }
    return out.toOwnedSlice(gpa);
}
