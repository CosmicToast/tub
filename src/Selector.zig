const std  = @import("std");
const uefi = std.os.uefi;

const globals = @import("globals.zig");
const text = @import("text.zig");

const Config  = @import("Config.zig");
const Console = @import("Console.zig");

const ReadKeyStrokeError = uefi.protocol.SimpleTextInput.ReadKeyStrokeError;
const WaitForEventError  = uefi.tables.BootServices.WaitForEventError;

const Self = @This();

const SelectorError = error {
    WriteFailed,
    RebootRequested,
    ExitRequested,
} || WaitForEventError || ReadKeyStrokeError;

cfg: *const Config,
con: *Console,

timer: Timer = Timer.empty,

group:   GroupWindow,
option: ?OptionWindow = null,

pub fn init(cfg: *const Config, con: *Console) Self {
    var out = Self{
        .cfg = cfg,
        .con = con,
        .group = GroupWindow.init(cfg.items, cfg.pagelen),
    };
    if (cfg.timeout > 0) {
        out.timer = Timer.create(cfg.timeout) catch Timer.empty;
    }
    return out;
}

// TODO: destroy

pub fn step(self: *Self) SelectorError!?Config.Option {
    try self.redraw();

    if (try self.con.waitForKey(self.timer.event))
        return self.input(try self.con.readInput());
    if (self.timer.tick())
        return self.cfg.defaultOption();
    return null;
}

fn select(self: *Self, value: ?usize) ?Config.Option {
    if (self.option) |*option| {
        if (value) |v| {
            if (option.onPage(v)) {
                option.cursor = v;
            } else return null;
        }
        return option.select();
    }

    if (value) |v|
        if (self.group.onPage(v)) {
            self.group.cursor = v;
        } else return null;
    const options = self.group.select().items;
    if (options.len > 0)
        self.option = OptionWindow.init(options, self.cfg.pagelen);
    return null;
}

fn input(self: *Self, in: Console.Input) SelectorError!?Config.Option {
    // TODO: destroy?
    // if a timer is running, stop it
    self.timer.destroy() catch {};

    switch (in) {
        .down_arrow => {
            if (self.option) |*option| {
                option.down(1);
            } else {
                self.group.down(1);
            }
        },
        .up_arrow => {
            if (self.option) |*option| {
                option.up(1);
            } else {
                self.group.up(1);
            }
        },
        .page_down => {
            if (self.option) |*option| {
                option.down(option.size);
            } else {
                self.group.down(self.group.size);
            }
        },
        .page_up => {
            if (self.option) |*option| {
                option.up(option.size);
            } else {
                self.group.up(self.group.size);
            }
        },

        .right_arrow => {
            if (self.select(null)) |o| return o;
        },

        .escape, .left_arrow => {
            if (self.option) |_| self.option = null;
        },

        .delete => {
            return SelectorError.RebootRequested;
        },

        .home => {
            return SelectorError.ExitRequested;
        },

        .text => |c| switch (c) {
            '\r' => if (self.select(null)) |o| return o,
            'a'...'z' => {
                const idx = c - 'a';
                if (self.select(idx)) |o| return o;
            },
            'A'...'Z' => {
                const idx = c - 'A';
                // TODO: line editor
                if (self.select(idx)) |o| return o;
            },

            else => {}
        },

        else => {}
    }
    return null;
}

fn redraw(self: Self) error{WriteFailed}!void {
    self.con.clear();
    try self.format(&self.con.writer);
}

pub fn format(self: Self, w: *std.Io.Writer) error{WriteFailed}!void {
    try self.formatTimer(w);
    try self.formatPrompt(w);
    if (self.option) |o| try o.format(w)
    else try self.group.format(w);
}

fn formatTimer(self: Self, w: *std.Io.Writer) error{WriteFailed}!void {
    if (self.timer.running()) {
        const opt = self.cfg.defaultOption();
        return w.print("Booting default option in {:02}s: {f} > {f}\r\n", .{
            self.timer.counter, opt.parent, opt
        });
    }
    return w.writeAll("\r\n");
}

fn formatPrompt(self: Self, w: *std.Io.Writer) error{WriteFailed}!void {
    if (self.option) |_|
        // return w.writeAll("Select boot option:\r\n");
        return w.print("Select boot option: {f} >\r\n", .{
            self.group.select()
        });
    return w.writeAll("Select boot group:\r\n");
}

const GroupWindow  = Window(Config.Group);
const OptionWindow = Window(Config.Option);
fn Window(comptime T: type) type {
    return struct {
        const Win = @This();

        from: usize = 0, size: usize = 0,
        cursor: usize = 0,
        data: []const T,

        pub fn init(data: []const T, size: usize) Win {
            if (data.len > size) return .{ .size = size, .data = data };
            return .{ .size = data.len, .data = data };
        }

        inline fn to(self: Win) usize { return self.from + self.size; }
        inline fn over(self: Win) usize {
            // max = len -| size; over = from -| max => from -| (len -| size)
            return self.from -| (self.data.len -| self.size);
        }

        pub fn window(self: Win) []const T {
            return self.data[self.from..][0..self.size];
        }

        pub fn down(self: *Win, by: usize) void {
            // if the cursor can move `by` in the current window, do that
            if (self.size - self.cursor >= by) {
                self.cursor += by;
                return;
            }
            // if the window can move at all, move it `by` or at least as far as it'll go
            if (self.to() < self.data.len) {
                self.from += by;
                self.from -|= self.over();
                return;
            }
            // the window cannot move at all, so move the cursor to the end
            self.cursor = self.size - 1;
        }

        pub fn up(self: *Win, by: usize) void {
            // if the cursor can move `by` in the current window, do that
            if (self.cursor >= by) {
                self.cursor -= by;
                return;
            }
            // if the window can move at all, move it `by` or at least as far as it'll go
            if (self.from > 0) {
                self.from -|= by;
                return;
            }
            // else move the cursor to the start
            self.cursor = 0;
        }

        pub fn format(self: Win, w: *std.Io.Writer) error{WriteFailed}!void {
            const s = self.window();
            for (s, 0..) |e, i| {
                const c: u21 = @as(u21, if (i == self.cursor) '>' else ' ');
                const l: u21 = @truncate(i + 'a');
                try w.print("{u}{u} {f}\r\n", .{c, l, e});
            }
        }

        pub fn select(self: Win) T {
            return self.window()[self.cursor];
        }

        // helper to know if label is in range
        pub fn onPage(self: Win, idx: usize) bool {
            return idx < self.size;
        }
    };
}

const Timer = struct {
    event: ?uefi.Event = null,
    counter: usize = 0,

    const second: u64 = @intCast(@divTrunc(
            std.Io.Duration.fromSeconds(1).toNanoseconds(), 100
    ));

    pub inline fn running(self: Timer) bool {
        return self.event != null;
    }

    pub fn cancel(self: *Timer) !void {
        if (self.event) |ev|
            try globals.boot_services.setTimer(ev, .cancel, 0);
    }

    pub fn tick(self: *Timer) bool {
        self.counter -|= 1;
        if (self.counter == 0) {
            self.cancel() catch {};
            return true;
        }
        return false;
    }

    pub fn create(seconds: usize) !Timer {
        const bs = globals.boot_services;

        const timer = try bs.createEvent(.{.timer = true,}, .{});
        errdefer bs.closeEvent(timer) catch {};

        try bs.setTimer(timer, .periodic, second);
        return .{ .event = timer, .counter = seconds };
    }

    pub fn destroy(self: *Timer) !void {
        try self.cancel();
        if (self.event) |ev|
            try globals.boot_services.closeEvent(ev);
        self.event = null;
    }

    const empty: Timer = .{};
};
