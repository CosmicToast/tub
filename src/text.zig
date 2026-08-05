const std = @import("std");
const unicode = std.unicode;

const Config = @import("Config.zig");

const Error = std.os.uefi.Error;

pub fn glob(pattern: anytype, text: anytype) bool {
    // TODO: maybe error?
    var pat = Iterator.create(pattern) catch return false;
    var txt = Iterator.create(text)    catch return false;
    return globWorker(&pat, &txt);
}

fn globWorker(pat: *Iterator, txt: *Iterator) bool {
    while (pat.nextCodepoint()) |c| {
        if (c != '*') {
            if (txt.nextCodepoint()) |v| {
                if (v != c) return false;
                continue;
            } else return false;
        }
        // c == '*'

        // if we end on a '*', all remnants are guaranteed to match
        if (pat.peekCodepoint() == null) return true;

        while (true) {
            // copy to effectively save position
            var pat2 = pat.*; var txt2 = txt.*;
            if (globWorker(&pat2, &txt2)) return true;

            // we're out of text, but there's more characters to glob
            // this also advances the pointer
            if (txt.nextCodepoint() == null) return false;
        }
    }
    // ran out of codepoints in pattern, make sure text is empty
    return txt.peekCodepoint() == null;
}

const Iterator = union(enum) {
    utf8: unicode.Utf8Iterator,
    ucs2: struct {
        data: []const u16,
        idx: usize,

        pub fn peekCodepoint(self: @This()) ?u21 {
            if (self.data.len == self.idx) return null;
            return self.data[self.idx];
        }

        pub fn nextCodepoint(self: *@This()) ?u21 {
            if (self.data.len == self.idx) return null;
            self.idx += 1;
            return self.data[self.idx - 1];
        }
    },

    pub inline fn peekCodepoint(self: *Iterator) ?u21 {
        return switch (self.*) {
            .utf8 => |*it| it.peekCodepoint(),
            .ucs2 => |*it| it.peekCodepoint(),
        };
    }

    pub inline fn nextCodepoint(self: *Iterator) ?u21 {
        return switch (self.*) {
            .utf8 => |*it| it.nextCodepoint(),
            .ucs2 => |*it| it.nextCodepoint(),
        };
    }

    pub fn create(data: anytype) !Iterator {
        return switch (@TypeOf(data)) {
            unicode.Utf8View => .{ .utf8 = data.iterator() },
            else => |T| switch (std.meta.Elem(T)) {
                u8  => Iterator.create(try unicode.Utf8View.init(data)),
                u16 => .{ .ucs2 = .{ .data = data, .idx = 0 }},
                else => @compileError("unknown type to iterate on"),
            }
        };
    }
};

// UCS-2 <-> UTF-8 utilities
pub fn calcUcs2Len(utf8: []const u8) Error!usize {
    const view = unicode.Utf8View.init(utf8)
        catch return Error.InvalidParameter;
    var it = view.iterator();
    var idx: usize = 0;
    while (it.nextCodepoint()) |c| : (idx += 1) {
        if (c > 0xfff) return Error.InvalidParameter;
    }
    return idx;
}

pub fn utf8ToUcs2(ucs2: []u16, utf8: []const u8) Error!usize {
    const view = unicode.Utf8View.init(utf8)
        catch return error.InvalidParameter;
    var it = view.iterator();
    var idx: usize = 0;
    while (it.nextCodepoint()) |c| : (idx += 1) {
        if (c > 0xffff) return error.InvalidParameter;
        ucs2[idx] = @truncate(c);
    }
    return idx;
}

pub fn utf8ToUcs2Literal(
    comptime utf8: []const u8
) *const [calcUcs2Len(utf8) catch |err| @compileError(err):0]u16 {
    return comptime blk: {
        const len: usize = calcUcs2Len(utf8) catch unreachable;
        var ucs2: [len:0]u16 = undefined;
        const ucs2Len = utf8ToUcs2(&ucs2, utf8[0..])
            catch |err| @compileError(err);
        std.debug.assert(len == ucs2Len);
        const final = ucs2;
        break :blk &final;
    };
}

pub fn calcUtf8Len(ucs2: []const u16) Error!usize {
    var size: usize = 0;
    for (ucs2) |c| {
        size += unicode.utf8CodepointSequenceLength(c)
            catch return Error.InvalidParameter;
    }
    return size;
}

pub fn ucs2ToUtf8(utf8: []u8, ucs2: []const u16) Error!usize {
    var idx: usize = 0;
    for (ucs2) |c| {
        idx += unicode.utf8Encode(c, utf8[idx..])
            catch return Error.InvalidParameter;
    }
    return idx;
}

pub fn ucs2ToUtf8Literal(
    comptime ucs2: []const u16
) *const [calcUtf8Len(ucs2) catch |err| @compileError(err):0]u8 {
    return comptime blk: {
        const len: usize = calcUtf8Len(ucs2);
        var utf8: [len:0]u8 = undefined;
        const utf8Len = ucs2ToUtf8(&utf8, ucs2)
            catch |err| @compileError(err);
        std.debug.assert(len == utf8Len);
        const final = utf8;
        break :blk &final;
    };
}

pub const Sorter = packed struct {
    path: bool,    // compare full path rather than filename
    reverse: bool, // greatest goes first
    // TODO: other modes?

    pub fn lessFn(comptime T: type
    ) fn (self: Sorter, lhs: T, rhs: T) bool {
        return switch (T) {
            []const u8, []u8 => lessThanStr,
            Config.Option    => lessThanOption,
            else => @compileError("can't generate lessFn for unknown type"),
        };
    }

    pub fn lessThanOption(self: Sorter, lhs: Config.Option, rhs: Config.Option) bool {
        return lessThanStr(self, lhs.path, rhs.path);
    }
    pub fn lessThanStr(self: Sorter, lhs: []const u8, rhs: []const u8) bool {
        const l, const r = blk: {
            if (self.path) break :blk .{lhs, rhs};
            break :blk .{path.filename(lhs), path.filename(rhs)};
        };
        return std.mem.lessThan(u8, l, r) ^ self.reverse;
    }

    pub fn init(conf: []const u8) Sorter {
        var out = Sorter{ .path = false, .reverse = false };
        for (conf) |c| {
            switch (c) {
                'p', 'P' => out.path    = 'p' == c,
                'r', 'R' => out.reverse = 'r' == c,
                else => {},
            }
        }
        return out;
    }

    pub inline fn sort(self: Sorter, items: anytype) void {
        const T = std.meta.Elem(@TypeOf(items));
        const F = lessFn(T);
        return std.mem.sort(T, items, self, F);
    }
};

/// Utilities to work with paths.
pub const path = struct {
    /// Returns the filename component of a path.
    /// If buf contains a '\', then this is everything after the last '\'.
    /// Otherwise, this is the entire path.
    pub fn filename(buf: []const u8) []const u8 {
        return if (std.mem.findScalarLast(u8, buf, '\\')) |last|
            buf[last+1..] else buf;
    }

    /// Returns the basename of a path, meaning the filename without the extension.
    /// If the filename (see `filename`) contains a '.',
    /// then this is everything up to that '.'.
    /// Otherwise this is the entire path.
    ///
    /// You can change these together to remove successive extensions.
    /// For example "\foo\bar.tar.gz" => "bar.tar" => "bar".
    pub fn basename(buf: []const u8) []const u8 {
        const file = filename(buf);
        return if (std.mem.findScalarLast(u8, file, '.')) |last|
            file[0..last] else file;
    }

    /// Returns the extension of a path, meaning only the extension.
    /// If the filename (see `filename`) contains a '.',
    /// then this is everything after that '.'.
    /// Otherwise, this is the empty string.
    pub fn extension(buf: []const u8) []const u8 {
        const file = filename(buf);
        return if (std.mem.findScalarLast(u8, file, '.')) |last|
            file[last+1..] else "";
    }

    /// Returns the directory component of a path.
    /// If buf contains a '\', this is everything up to the last '\'.
    /// Otherwise this is the empty string.
    pub fn dirname(buf: []const u8) []const u8 {
        return if (std.mem.findScalarLast(u8, buf, '\\')) |last|
            buf[0..last] else "";
    }

    /// This is a utility to convert from the config file format to UEFI format.
    /// Essentially that just means replacing '/'s by '\'s.
    pub inline fn convert(buf: []u8) void {
        std.mem.replaceScalar(u8, buf, '/', '\\');
    }
};
