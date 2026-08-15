//! Gap-buffer based editor for the cmdline.
const std = @import("std");

const Console = @import("Console.zig");
const text = @import("text.zig");

const Editor = @This();

/// Backing gap buffer.
buf: Buffer,
/// Pointer to the console to communicate with.
con: *Console,

inline fn ctrlCode(c: u21) u21 {
    // ^a-z = 1-26
    return c - 'a' + 1;
}

/// Creates an Editor and runs it as a state machine until an error occurs, the
/// user submits the result, or the user cancels the editing process.
/// Null means the user has cancelled, so an empty slice means the user
/// explicitly requested such.
pub fn edit(initial: []const u8, gpa: std.mem.Allocator) !?[]const u16 {
    const len = try text.calcUcs2Len(initial);
    const buf = try gpa.alloc(u16, len * 2);
    const real = try text.utf8ToUcs2(buf, initial);
    std.debug.assert(len == real);
    var con = Console.init();
    var self: Editor = .{
        .buf = .{ .data = buf, .left = len, .right = 0 },
        .con = &con,
    };

    while (true) {
        try self.redraw();
        _ = try self.con.waitForKey(null);
        const in = try self.con.readInput();
        const state = try self.input(in, gpa);
        if (state == null) continue;
        return switch (state.?) {
            .quit => null,
            .submit => |v| v,
        };
    }
}

fn redraw(self: *Editor) !void {
    self.con.clear();
    self.con.setCursor(.disabled) catch {};
    try self.buf.format(&self.con.writer);
}

fn input(self: *Editor, key: Console.Input, gpa: std.mem.Allocator) !?union(enum) {
    quit,
    submit: []const u16,
} {
    switch (key) {
        .left_arrow => self.buf.move(.left),
        .right_arrow => self.buf.move(.right),
        .home => self.buf.move(.start),
        .end => self.buf.move(.end),
        .delete => self.buf.delete(),

        .escape => return .quit,
        .text => |c| switch (c) {
            ctrlCode('a') => self.buf.move(.start), // ^a: start of line
            ctrlCode('b') => self.buf.move(.left), // ^b: move backwards
            ctrlCode('d') => self.buf.delete(), // ^d: delete
            ctrlCode('e') => self.buf.move(.end), // ^e: end of line
            ctrlCode('f') => self.buf.move(.right), // ^f: move forwards
            ctrlCode('h') => self.buf.backspace(), // ^h: backspace
            ctrlCode('k') => self.buf.killLine(), // ^k: kill line
            ctrlCode('u') => self.buf.killWholeLine(), // ^u: kill whole line

            // NOTE: \r and ^m are the same!
            ctrlCode('j'), '\r' => return .{ .submit = self.buf.finish() },
            // ASCII printable range
            32...126 => {
                try self.buf.grow(gpa);
                self.buf.insertAssert(c);
            },
            // TODO: is it even possible to enter other codepoints?
            else => {},
        },
        else => {},
    }
    return null;
}

/// A Gap Buffer implementation with some common editing commands predefined.
/// The caller is responsible for making sure grow is called with data's
/// allocator, as well as data's memory.
pub const Buffer = struct {
    /// Backing storage, typically around double the size of the current data.
    data: []u16,

    /// The size of the left buffer.
    /// You can get the left buffer as data[0..left].
    left: usize,

    /// The size of the right buffer.
    /// You can get the right buffer as data[data.len - right..].
    right: usize,

    /// Convenience function to get the left buffer.
    inline fn leftb(self: Buffer) []u16 {
        return self.data[0..self.left];
    }

    /// Convenience function to get the right buffer.
    inline fn rightb(self: Buffer) []u16 {
        return self.data[self.data.len - self.right ..];
    }

    /// Convenience function to calculate the pressure.
    /// The pressure is defined as the % (0-1) of fullness of the backing buffer.
    inline fn pressure(self: Buffer) f64 {
        return (self.left + self.right) / self.data.len;
    }

    /// Resizes the data buffer if it is past the grow pressure threshold (0.75)
    /// such that the new pressure is 0.5.
    pub fn grow(self: *Buffer, gpa: std.mem.Allocator) !void {
        const target = if (self.data.len == 0) 16 else (self.left + self.right) * 2;
        if (target / 3 * 2 < self.data.len) return;

        const oldlen = self.data.len;
        if (!gpa.resize(self.data, target)) {
            // resize failed: either couldn't be moved or OoM
            const new = try gpa.alloc(u16, target);

            @memcpy(new[0..self.left], self.leftb());
            @memcpy(new[new.len - self.right ..], self.rightb());

            gpa.free(self.data);
            self.data = new;
        } else {
            const old = self.data[0..oldlen];
            @memmove(self.rightb(), old[old.len - self.right ..]);
        }
    }

    /// Move the cursor to the logical position in the buffer.
    pub fn move(self: *Buffer, how: union(enum) {
        left,
        right,
        start,
        end,
        to: usize,
    }) void {
        const pos = switch (how) {
            .left => self.left -| 1,
            .right => self.left +| 1,
            .start => 0,
            .end => self.left + self.right,
            .to => |v| v,
        };
        if (pos > self.left + self.right)
            return @call(.always_tail, move, .{ self, .end });
        if (pos == self.left) return;
        const rstart = self.data.len - self.right;

        if (pos > self.left) {
            const count = pos - self.left;
            const dst = self.data[self.left..][0..count];
            const src = self.data[rstart..][0..count];
            @memmove(dst, src);
            self.left += count;
            self.right -= count;
        } else {
            const count = self.left - pos;
            const dst = self.data[rstart - count ..][0..count];
            const src = self.data[pos..][0..count];
            @memmove(dst, src);
            self.left -= count;
            self.right += count;
        }
    }

    /// Convenience function to consolidate the data (by moving the cursor to the end)
    /// and returning the resulting slice.
    pub inline fn finish(self: *Buffer) []const u16 {
        self.move(.end);
        return self.leftb();
    }

    /// See std.Io.Writer.print.
    pub fn format(self: *Buffer, w: *std.Io.Writer) !void {
        for (self.leftb()) |c| try w.printUnicodeCodepoint(c);
        // 0x2588 is the BLOCKELEMENT LIGHT SHADE
        // it's the best "cursor-like" I can do in theory, I think
        //
        // why do I have to do this weird soft cursor thing?
        // so, unfortunately, cursor positioning / mode geometry
        // is implementation-driven, and it turns out, implementations SUCK
        // the reports are just way off on the reads, but seemingly correct on writes
        // which means that I simply cannot get cursor positions or geometry and trust it
        //
        // this means a soft cursor is necessary. this is where more bad news comes in
        // implementations are required to support a few drawing characters
        // they don't seem to be required to support anything else
        // furthermore, "support" doesn't mean "draw to spec"
        // it just means "draw something". EDK2 draws a "*" for this one, for example
        //
        // ultimately though, this is just about as good as it's going to get
        // I can't detect the wrong character being used or being absent
        // I can't detect the mode lying to me
        // so I just pick the closest "seems reasonable" character and hope for the best
        // hopefully you won't need to edit your cmdline *too* often :D
        try w.printUnicodeCodepoint(0x2588);
        for (self.rightb()) |c| try w.printUnicodeCodepoint(c);
    }

    /// Insert a codepoint into the left buffer (so at the cursor).
    /// This presumes that the buffer has the space needed to do so.
    pub fn insertAssert(self: *Buffer, c: u21) void {
        std.debug.assert(c < 0xffff);
        std.debug.assert(self.left + self.right < self.data.len);
        self.data[self.left] = @truncate(c);
        self.left += 1;
    }

    // common editing commands

    /// Remove the codepoint prior to the cursor.
    pub inline fn backspace(self: *Buffer) void {
        if (self.left > 0) self.left -= 1;
    }

    /// Remove the codepoint after the cursor.
    pub inline fn delete(self: *Buffer) void {
        if (self.right > 0) self.right -= 1;
    }

    /// Remove everything after the cursor.
    pub inline fn killLine(self: *Buffer) void {
        self.right = 0;
    }

    /// Remove everything.
    pub inline fn killWholeLine(self: *Buffer) void {
        self.left = 0;
        self.right = 0;
    }
};
