//! Tools to deal with UEFI text. UEFI uses the UCS-2 encoding and
//! does not have implementations for things like globbing or encoding
//! conversions.
const std = @import("std");
const uni = std.unicode;
const Error = std.os.uefi.Error;

/// Returns the lowercase variant of codepoint `c`. Only supports
/// ASCII at the moment.
inline fn toLower(c: u21) u8 {
    std.debug.assert(c < 128);
    return std.ascii.toLower(@truncate(c));
}

/// Try to match `text` against globbing `pattern`. Returns true if a
/// match is found.
/// This function supports both UTF-8 strings and UCS-2 strings
/// implicitly. This is achieved by having a generic `Iterator`
/// type. See its documentation for further details.
/// Note that the match is "global" and anchored, meaning that if
/// pattern starts with an "a" and ends with an "e", then `text` must
/// start with an "a" and end with an "e" to match as well.
pub fn glob(pattern: anytype, text: anytype) bool {
    // TODO: maybe error?
    var pat = Iterator.create(pattern) catch return false;
    var txt = Iterator.create(text) catch return false;
    return globWorker(&pat, &txt);
}

/// Performs the work of `glob` by operating on the Iterators.
fn globWorker(pat: *Iterator, txt: *Iterator) bool {
    while (pat.nextCodepoint()) |c| {
        if (c != '*') {
            if (txt.nextCodepoint()) |v| {
                if (v == c) continue else if (v > 128 or c > 128) return false else if (toLower(v) == toLower(c)) continue else return false;
            } else return false;
        }
        // c == '*'

        // if we end on a '*', all remnants are guaranteed to match
        if (pat.peekCodepoint() == null) return true;

        while (true) {
            // copy to effectively save position
            var pat2 = pat.*;
            var txt2 = txt.*;
            if (globWorker(&pat2, &txt2)) return true;

            // we're out of text, but there's more characters to glob
            // this also advances the pointer
            if (txt.nextCodepoint() == null) return false;
        }
    }
    // ran out of codepoints in pattern, make sure text is empty
    return txt.peekCodepoint() == null;
}

/// A generic codepoint iterator that can walk over UTF-8 or UCS-2
/// text. It provides the functions we need, notably `nextCodepoint`
/// and `peekCodepoint`, which are compatible with
/// `std.unicode.Utf8Iterator`.
const Iterator = union(enum) {
    utf8: uni.Utf8Iterator,
    ucs2: struct {
        data: []const u16,
        idx: usize,

        /// Returns the next codepoint without advancing the iterator.
        pub fn peekCodepoint(self: @This()) ?u21 {
            if (self.data.len == self.idx) return null;
            return self.data[self.idx];
        }

        /// Returns the next codepoint, advancing the iterator.
        pub fn nextCodepoint(self: *@This()) ?u21 {
            if (self.data.len == self.idx) return null;
            self.idx += 1;
            return self.data[self.idx - 1];
        }
    },

    /// Returns the next codepoint without advancing the iterator.
    pub inline fn peekCodepoint(self: *Iterator) ?u21 {
        return switch (self.*) {
            .utf8 => |*it| it.peekCodepoint(),
            .ucs2 => |*it| it.peekCodepoint(),
        };
    }

    /// Returns the next codepoint, advancing the iterator.
    pub inline fn nextCodepoint(self: *Iterator) ?u21 {
        return switch (self.*) {
            .utf8 => |*it| it.nextCodepoint(),
            .ucs2 => |*it| it.nextCodepoint(),
        };
    }

    /// Creates a codepoint iterator from a list of u8 (UTF-8 text) or
    /// u16 (UCS-2 text). Trying to call this with any other type will
    /// cause a compile-time error.
    pub fn create(data: anytype) !Iterator {
        return switch (@TypeOf(data)) {
            uni.Utf8View => .{ .utf8 = data.iterator() },
            else => |T| switch (std.meta.Elem(T)) {
                u8 => Iterator.create(try uni.Utf8View.init(data)),
                u16 => .{ .ucs2 = .{ .data = data, .idx = 0 } },
                else => @compileError("unknown type to iterate on"),
            },
        };
    }
};

/// Calculates the length a UCS-2 buffer needs to be to encode all the
/// codepoints in the given `utf8` text.
pub fn calcUcs2Len(utf8: []const u8) Error!usize {
    const view = uni.Utf8View.init(utf8) catch return Error.InvalidParameter;
    var it = view.iterator();
    var idx: usize = 0;
    while (it.nextCodepoint()) |c| : (idx += 1) {
        if (c > 0xfff) return Error.InvalidParameter;
    }
    return idx;
}

/// Converts the text in `utf8` to the UCS-2 encoding, writing it to
/// `ucs2`. This assumes that `ucs2` is big enough, causing runtime
/// illegal behavior if it isn't.
pub fn utf8ToUcs2(ucs2: []u16, utf8: []const u8) Error!usize {
    const view = uni.Utf8View.init(utf8) catch return error.InvalidParameter;
    var it = view.iterator();
    var idx: usize = 0;
    while (it.nextCodepoint()) |c| : (idx += 1) {
        if (c > 0xffff) return error.InvalidParameter;
        ucs2[idx] = @truncate(c);
    }
    return idx;
}

/// Converts a literal (or otherwise comptime-known) `utf8` text to
/// UCS-2 at comptime.
pub fn utf8ToUcs2Literal(comptime utf8: []const u8) *const [calcUcs2Len(utf8) catch |err| @compileError(err):0]u16 {
    return comptime blk: {
        const len: usize = calcUcs2Len(utf8) catch unreachable;
        var ucs2: [len:0]u16 = undefined;
        const ucs2Len = utf8ToUcs2(&ucs2, utf8[0..]) catch |err| @compileError(err);
        std.debug.assert(len == ucs2Len);
        const final = ucs2;
        break :blk &final;
    };
}

/// Calculates the length a UTF-8 buffer needs to be to encode all the
/// codepoints in a given `ucs2` text.
pub fn calcUtf8Len(ucs2: []const u16) Error!usize {
    var size: usize = 0;
    for (ucs2) |c| {
        size += uni.utf8CodepointSequenceLength(c) catch return Error.InvalidParameter;
    }
    return size;
}

/// Converts the text in `ucs2` to the UTF-8 encoding, writing it to
/// `utf8`. This assumes that `utf8` is big enough, causing runtime
/// illegal behavior if it isn't.
pub fn ucs2ToUtf8(utf8: []u8, ucs2: []const u16) Error!usize {
    var idx: usize = 0;
    for (ucs2) |c| {
        idx += uni.utf8Encode(c, utf8[idx..]) catch return Error.InvalidParameter;
    }
    return idx;
}

/// Converts a literal (or otherwise comptime-known) `ucs2` text to
/// UTF-8 at comptime.
pub fn ucs2ToUtf8Literal(comptime ucs2: []const u16) *const [calcUtf8Len(ucs2) catch |err| @compileError(err):0]u8 {
    return comptime blk: {
        const len: usize = calcUtf8Len(ucs2);
        var utf8: [len:0]u8 = undefined;
        const utf8Len = ucs2ToUtf8(&utf8, ucs2) catch |err| @compileError(err);
        std.debug.assert(len == utf8Len);
        const final = utf8;
        break :blk &final;
    };
}

/// A generic configurable sorter. See members for what options it
/// supports.
pub const Sorter = packed struct {
    /// Compare full path rather than filename. If this is unset,
    /// inputs will be replaced by the output of `path.filename` on
    /// them.
    path: bool,
    /// Later-sorting inputs will end up earlier in the list,
    /// i.e. sort in reverse.
    reverse: bool,
    // TODO: other modes?

    /// A `lessFn` for use with `std.mem.sort` that takes a Sorter as
    /// an argument, operating exclusively on UTF-8-formatted strings.
    pub fn lessFn(self: Sorter, lhs: []const u8, rhs: []const u8) bool {
        const l, const r = blk: {
            if (self.path) break :blk .{ lhs, rhs };
            break :blk .{ path.filename(lhs), path.filename(rhs) };
        };
        return std.mem.lessThan(u8, l, r) ^ self.reverse;
    }

    /// Parses a flag-string into a Sorter configuration.
    pub fn init(conf: []const u8) Sorter {
        var out = Sorter{ .path = false, .reverse = false };
        for (conf) |c| {
            switch (c) {
                'p', 'P' => out.path = 'p' == c,
                'r', 'R' => out.reverse = 'r' == c,
                else => {},
            }
        }
        return out;
    }

    /// Helper function that will sort `items` by a subfield of theirs
    /// `field_name`, which must be a UTF-8 string.
    pub inline fn sortField(self: Sorter, comptime T: type, items: []T, comptime field_name: []const u8) void {
        const F = struct {
            pub fn lessFn(s: Sorter, lhs: T, rhs: T) bool {
                const l = @field(lhs, field_name);
                const r = @field(rhs, field_name);
                return s.lessFn(l, r);
            }
        }.lessFn;
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
            buf[last + 1 ..]
        else
            buf;
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
            file[0..last]
        else
            file;
    }

    /// Returns the extension of a path, meaning only the extension.
    /// If the filename (see `filename`) contains a '.',
    /// then this is everything after that '.'.
    /// Otherwise, this is the empty string.
    pub fn extension(buf: []const u8) []const u8 {
        const file = filename(buf);
        return if (std.mem.findScalarLast(u8, file, '.')) |last|
            file[last + 1 ..]
        else
            "";
    }

    /// Returns the directory component of a path.
    /// If buf contains a '\', this is everything up to the last '\'.
    /// Otherwise this is the empty string.
    pub fn dirname(buf: []const u8) []const u8 {
        return if (std.mem.findScalarLast(u8, buf, '\\')) |last|
            buf[0..last]
        else
            "";
    }

    /// This is a utility to convert from the config file format to UEFI format.
    /// Essentially that just means replacing '/'s by '\'s.
    pub inline fn convert(buf: []u8) void {
        std.mem.replaceScalar(u8, buf, '/', '\\');
    }
};
