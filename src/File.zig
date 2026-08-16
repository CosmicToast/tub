//! Wrapper around UEFI Files.
const std = @import("std");
const mem = std.mem;
const uefi = std.os.uefi;
const Error = uefi.Error;
const Allocator = std.mem.Allocator;
const File = uefi.protocol.File;
const Info = File.Info.File;

const globals = @import("globals.zig");
const text = @import("text.zig");

// Self to avoid conflicting with uefi.protocol.File
const Self = @This();

/// Backing opaque file pointer. Normally open, it needs to be closed.
file: *File,
/// The buffer that holds the FileInfo. Unfortunately this has to be a
/// buffer for a few annoying reasons, mostly to do with flexible
/// array members.
ibuf: []align(8) u8,

/// Create a File wrapper from a uefi.protocol.File, taking ownership
/// of the handle. This means that when you call destroy(), the
/// backing file will be closed.
pub fn create(file: *File, alloc: Allocator) Error!Self {
    const isz = try file.getInfoSize(.file);
    const ibuf = alloc.alignedAlloc(u8, .@"8", isz) catch return Error.OutOfResources;
    _ = try file.getInfo(.file, ibuf);
    return .{ .file = file, .ibuf = ibuf };
}

/// Create a File wrapper from the booted image. This depends on the
/// globals being initialized, since the SimpleFileProtocol obtained
/// from the LoadedImage is set up there once at startup.
pub fn fromImage(alloc: Allocator) Error!Self {
    return create(globals.sfs.openVolume() catch return error.MediaChanged, alloc) catch error.OutOfResources;
}

/// Destroy the file, freeing the Info buffer and closing the
/// file. This eats errors to make them silent, since there's not much
/// to be done about it anyway: you're no longer interested in the
/// file.
pub fn destroy(self: *Self, alloc: Allocator) void {
    alloc.free(self.ibuf);
    // if we fail to close it there's not much we can do about it anyway
    self.file.close() catch {};
}

/// Open `path` relative to this file, where `path` is formatted as
/// UCS-2. This takes fewer steps than `open`, meaning that if you can
/// know your path at comptime, it is much better to call `openUcs2`
/// against a `text.utf8ToUcs2Literal` than it is to call `open` on a
/// UTF-8 literal.
pub fn openUcs2(self: Self, alloc: Allocator, path: [*:0]const u16) Error!Self {
    return create(try self.file.open(path, .read, .{}), alloc);
}

/// Open `path` relative to this file, where `path` is formatted as UTF-8.
pub fn open(self: Self, alloc: Allocator, path: []const u8) Error!Self {
    const psz = try text.calcUcs2Len(path);
    const pbuf = alloc.allocSentinel(u16, psz, 0) catch return Error.OutOfResources;
    defer alloc.free(pbuf);

    const rsz = try text.utf8ToUcs2(pbuf, path);
    std.debug.assert(rsz == psz);

    return self.openUcs2(alloc, pbuf);
}

/// Read the entirety of this file into a contiguous buffer using
/// `alloc`, returning it. Note that you should never call this on a
/// directory.
pub fn slurp(self: Self, alloc: Allocator) ![]u8 {
    std.debug.assert(!self.info().attribute.directory);
    const esz = self.info().file_size;
    const buf = try alloc.alloc(u8, esz);
    errdefer alloc.free(buf);
    const rsz = try self.file.read(buf);
    std.debug.assert(esz == rsz);
    return buf; // free this yourself
}

/// Returns a pointer to the File Info from the pre-populated buffer.
pub fn info(self: Self) *const Info {
    return std.mem.bytesAsValue(Info, self.ibuf);
}

/// Returns the name of the current file as UCS-2.
pub fn name(self: Self) []const u16 {
    return mem.span(self.info().getFileName());
}

/// Returns the name of the current file as UTF-8. The caller owns the
/// resulting memory.
pub fn nameUtf8(self: Self, alloc: Allocator) ![]const u8 {
    const ucs2 = self.name();
    const bsz = text.calcUtf8Len(ucs2);
    const buf = alloc.alloc(u8, bsz);
    const rsz = text.ucs2ToUtf8(buf, ucs2);
    std.debug.assert(rsz == bsz);
    return buf; // free this yourself
}

/// An iterator over directory entries.
const Iterator = struct {
    /// The backing uefi File.
    file: *File,
    /// The pattern to match which, if set, will skip entries that do
    /// not match.
    pat: ?[]const u8,
    /// The fileinfo buffer, see Self.buf for further details. This is
    /// here so that only one allocation is needed at creation-time,
    /// rather than one on each next() step.
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

/// Instantiate an iterator over the directory `self`.
pub fn iterate(self: Self, alloc: Allocator) !Iterator {
    return try Iterator.init(self, alloc, null);
}

/// Instantiate an iterator over the directory `self` where all
/// returned filenames must match `pattern`.
pub fn glob(self: Self, pattern: []const u8, alloc: Allocator) !Iterator {
    return try Iterator.init(self, alloc, pattern);
}

/// Recursively get all filenames under the directory `self` that
/// match `pattern`.
/// `pattern` may either begin with "**", in which case all of the
/// filenames on the volume will be gathered and their internal path
/// representation matched against the pattern.
/// If `pattern` does not begin with a "*", it is taken as a
/// structured globbing pattern, meaning a wildcard only applies to a
/// single directory level.
/// For example, this means that if files ./a/b/c and ./a/c exist,
/// searching . for the pattern "a/*c" will not match ./a/b/c.
pub fn find(self: Self, pattern: []const u8, gpa: Allocator) ![][]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // recursive wildcard searching
    if (pattern.len > 1 and pattern[0] == pattern[1] and pattern[0] == '*') {
        const all = try self.findAll(alloc, alloc);
        var out = std.ArrayList([]u8).empty;
        for (all) |path| {
            if (text.glob(pattern[1..], path)) {
                try out.append(gpa, try gpa.dupe(u8, path));
            }
        }
        return try out.toOwnedSlice(gpa);
    }

    // structural searching
    var it = std.mem.splitScalar(u8, if (pattern[0] == '\\') pattern[1..] else pattern, '\\');
    return findParts(self, &it, gpa, alloc);
}

/// Internal helper for `find`.
fn findParts(self: Self, parts: *std.mem.SplitIterator(u8, .scalar), gpa: Allocator, arena: Allocator) ![][]u8 {
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
            const fullpath = try std.mem.join(gpa, "\\", &.{ file, subpath });
            try out.append(gpa, fullpath);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Internal helper for `find`.
fn findAll(self: Self, gpa: Allocator, arena: Allocator) ![][]u8 {
    var out = std.ArrayList([]u8).empty;
    var it = try self.iterate(arena);
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

    for (here) |file| {
        if (file[0] == '.') continue;
        var subdir = try self.open(arena, file);
        defer subdir.destroy(arena);

        // add files as-is
        if (!subdir.info().attribute.directory) {
            try out.append(gpa, file);
            continue;
        }

        // add everything under directory
        const subfiles = try subdir.findAll(arena, arena);
        for (subfiles) |subpath| {
            const fullpath = try std.mem.join(gpa, "\\", &.{ file, subpath });
            try out.append(gpa, fullpath);
        }
    }
    return out.toOwnedSlice(gpa);
}
