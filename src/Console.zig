//! Wraps UEFI's con_in and con_out to handle input and output.
//! The biggest catch is that both of these are in UCS-2.

const Self = @This();

const std     = @import("std");
const uefi    = std.os.uefi;
const unicode = std.unicode;

const text = @import("text.zig");

// Protocols
const STI = uefi.protocol.SimpleTextInput;
const STO = uefi.protocol.SimpleTextOutput;

// Tables
const BootServices = uefi.tables.BootServices;

writer: Writer,
input:  *STI,
output: *STO,

// Writing utilities.
pub fn clear(self: *Self) void {
    // if it doesn't work, then it doesn't work, that's fine
    self.output.clearScreen() catch {};
}

pub fn getCursor(self: *Self) union(enum) {
    disabled,
    enabled: struct {row: usize, col: usize },
} {
    const mode = self.output.mode;
    if (!mode.cursor_visible) return .disabled;
    return .{ .enabled = .{
        .row = @intCast(mode.cursor_row),
        .col = @intCast(mode.cursor_column),
    }};
}

pub fn setCursor(
    self: *Self,
    state: union(enum) {
        enabled, disabled,
        position: struct { row: usize, col: usize },
    },
) !void {
    switch (state) {
        .enabled  => try self.output.enableCursor(true),
        .disabled => try self.output.enableCursor(false),
        .position => |p| {
            try self.setCursor(.enabled);
            try self.output.setCursorPosition(p.col, p.row);
        },
    }
}

// std.Io.Writer; this is a bit evil btw
const Writer = std.Io.Writer;
fn drainStr(out: *STO, str: []const u8) Writer.Error!usize {
    // unchecked since we have to check for >0xffff anyway
    // this may be a mistake!
    const view = unicode.Utf8View.initUnchecked(str);
    var it = view.iterator();
    var size: usize = 0;
    while (it.nextCodepoint()) |char| {
        if (char > 0xffff) return error.WriteFailed;

        _ = out.outputString(&[_:0]u16{@truncate(char)})
            catch { return error.WriteFailed; }
            or    return error.WriteFailed;
        size += unicode.utf8CodepointSequenceLength(char)
            catch return error.WriteFailed;
    }
    return size;
}

fn drain (
    w: *Writer,
    data: []const []const u8,
    splat: usize
) Writer.Error!usize {
    const self: *Self = @fieldParentPtr("writer", w);

    // simplify later splatting logic
    const strs = if (splat == 0) data[0..data.len - 1] else data;

    var out: usize = 0;
    // w.end is never >0 if the implementation is unbuffered
    if (w.end > 0) {
        out += try drainStr(self.output, w.buffer[0..w.end]);
        w.end = 0;
    }
    for (strs) |str| out += try drainStr(self.output, str);
    // we already printed the first splat once
    for (0..splat - 1) |_| out += try drainStr(self.output, strs[strs.len - 1]);

    return out;
}

const VTable: Writer.VTable = .{
    .drain = drain,
};

// Use this to write a UCS-2 string with no extra processing.
pub fn writeUcs2(self: *Self, str: [:0]const u16) !void {
    if (!try self.output.outputString(str.ptr))
        return error.WriteFailed;
}

pub fn writeLiteral(self: *Self, comptime str: []const u8) !void {
    return self.writeUcs2(text.utf8ToUcs2Literal(str));
}

// Reading utilities

pub const Input = union(enum(u16)) {
    text: u21 = 0x0,

    // SIMPLE_TEXT_INPUT
    up_arrow    = 0x1,
    down_arrow  = 0x2,
    right_arrow = 0x3,
    left_arrow  = 0x4,
    home        = 0x5,
    end         = 0x6,
    insert      = 0x7,
    delete      = 0x8,
    page_up     = 0x9,
    page_down   = 0xa,
    fn1         = 0xb,
    fn2         = 0xc,
    fn3         = 0xd,
    fn4         = 0xe,
    fn5         = 0xf,
    fn6         = 0x10,
    fn7         = 0x11,
    fn8         = 0x12,
    fn9         = 0x13,
    fn10        = 0x14,
    escape      = 0x17,

    // SIMPLE_TEXT_INPUT_EX
    fn11            = 0x15,
    fn12            = 0x16,
    pause           = 0x48,
    fn13            = 0x68,
    fn14            = 0x69,
    fn15            = 0x6a,
    fn16            = 0x6b,
    fn17            = 0x6c,
    fn18            = 0x6d,
    fn19            = 0x6e,
    fn20            = 0x6f,
    fn21            = 0x70,
    fn22            = 0x71,
    fn23            = 0x72,
    fn24            = 0x73,
    mute            = 0x7f,
    vol_up          = 0x80,
    vol_down        = 0x81,
    brightness_up   = 0x100,
    brightness_down = 0x101,
    @"suspend"      = 0x102,
    hibernate       = 0x103,
    toggle_display  = 0x104,
    recovery        = 0x105,
    eject           = 0x106,
    // 0x8000-0xffff oem reserved

    pub fn fromInput(input: STI.Key.Input) Input {
        return switch (input.scan_code) {
            0 => .{ .text = input.unicode_char },
            inline 0x1...0x14, 0x17 => |sc| blk: {
                const inputTag: std.meta.Tag(Input) = @enumFromInt(sc);
                break :blk @unionInit(Input, @tagName(inputTag), {});
            },
            else => unreachable, // at least according to the spec :^)
        };
    }

    pub fn toInput(self: Input) STI.Key.Input {
        return switch (self) {
            .text => |c| .{ .scan_code = 0, .unicode_char = @truncate(c) },
            else => .{ .scan_code = @intFromEnum(self) }
        };
    }
};

pub fn waitForKey(self: *Self, event: ?uefi.Event) !enum{ input, event } {
    const bs = uefi.system_table.boot_services.?;
    var events = [2]uefi.Event{self.input.wait_for_key, self.input.wait_for_key};
    if (event) |e| {
        events[1] = e;
        _, const idx = try bs.waitForEvent(events[0..]);
        return if (idx == 0) .input else .event;
    }
    _ = try bs.waitForEvent(events[0..1]);
    return .input;
}

pub inline fn readInput(self: *Self) !Input {
    return Input.fromInput(try self.input.readKeyStroke());
}

/// Initializes a console manager from the uefi system table.
pub fn init() Self {
    return .{
        .writer= Writer {
            .buffer = &.{},
            .vtable = &VTable,
        },
        .input  = uefi.system_table.con_in.?,
        .output = uefi.system_table.con_out.?,
    };
}
