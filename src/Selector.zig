//! Selector UI for a realized tub configuration.
const std = @import("std");
const uefi = std.os.uefi;
const ReadKeyStrokeError = uefi.protocol.SimpleTextInput.ReadKeyStrokeError;
const WaitForEventError = uefi.tables.BootServices.WaitForEventError;
const WriterError = std.Io.Writer.Error;

const Config = @import("Config.zig");
const Console = @import("Console.zig");
const globals = @import("globals.zig");
const text = @import("text.zig");

const Selector = @This();

const SelectorError = WriterError || WaitForEventError || ReadKeyStrokeError;

/// The configuration this selector is selecting for.
cfg: *const Config,
/// The console this selector operates on.
con: *Console,

/// The default selection timer.
timer: Timer = Timer.empty,

/// A pager for the configuration group selection.
group: GroupWindow,
/// A pager for the option group selection, when a group has been picked.
option: ?OptionWindow = null,

/// Initialize a Selector from a materialized configuration.
/// This will also attempt to create a timer if the timeout is enabled
/// and a default option can be found.
pub fn init(cfg: *const Config, con: *Console) Selector {
    return Selector{
        .cfg = cfg,
        .con = con,
        .group = GroupWindow.init(cfg.items, cfg.pagelen),
        .timer = if (cfg.timeout > 0 and cfg.defaultOption() != null)
            Timer.create(cfg.timeout) catch Timer.empty
        else
            Timer.empty,
    };
}

// TODO: destroy

/// A Selector operates like a state machine for user input. The
/// Selection is the instruction for what the next step is, with the
/// intent that the caller drives the process.
pub const Selection = union(enum) {
    /// The user has requested the machine to be reboot.
    reboot,
    /// The user has requested that we exit tub. Usually this will
    /// imply dropping "back" to the UEFI boot selection, but may
    /// result in other things, like trying to boot from PXE (or just
    /// generally the next boot priority), or even a return to
    /// whatever launched tub to begin with.
    exit,
    /// The user has requested to boot the payload option as-is.
    boot: Config.Option,
    /// The user has requested to boot the payload option after
    /// editing its command line. Note that while editing, the user
    /// may change their mind and cancel the boot process, in which
    /// case they should be returned to this menu.
    edit: Config.Option,
};

/// Step the Selector state machine forward. This implies redrawing
/// the screen (since the user's selection may have updated since),
/// reading an input (or the timer triggering), and getting the next
/// step.
/// A return value of `null` means that the machine needs more inputs
/// (or timer triggers, or whatever) to come to a conclusion. A
/// Selection return means that the machine is finished running. The
/// caller should still keep the instance around in case the boot
/// fails, or the user cancels the boot while in the editor, and so
/// on.
pub fn step(self: *Selector) SelectorError!?Selection {
    try self.redraw();

    return switch (try self.con.waitForKey(self.timer.event)) {
        .input => self.input(try self.con.readInput()),
        .event => if (self.timer.tick())
            if (self.cfg.defaultOption()) |o|
                .{ .boot = o }
            else
                null
        else
            null,
    };
}

/// This action runs when the user selects an option in the UI,
/// whether to edit or not. If in a Group selector, the Selector will
/// advance to selecting the Option within the selected Group. If in a
/// Option selector, the specific Option is materialized and returned.
pub fn select(self: *Selector, value: ?usize) ?Config.Option {
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

/// Processes a single keyboard input. See the context of this
/// function if you want to know what keys do what precisely.
fn input(self: *Selector, in: Console.Input) SelectorError!?Selection {
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
            if (self.select(null)) |o| return .{ .boot = o };
        },

        .escape, .left_arrow => {
            if (self.option) |_| self.option = null;
        },

        .delete => return .reboot,
        .home => return .exit,

        .text => |c| return switch (c) {
            '\r' => if (self.select(null)) |o| .{ .boot = o } else null,
            'a'...'z' => if (self.select(c - 'a')) |o| .{ .boot = o } else null,
            'A'...'Z' => if (self.select(c - 'A')) |o| .{ .edit = o } else null,
            else => null,
        },

        else => {},
    }
    return null;
}

/// Clears the screen, then formats itself.
fn redraw(self: Selector) error{WriteFailed}!void {
    self.con.clear();
    try self.format(&self.con.writer);
}

/// Prints the Selector UI to `w`.
pub fn format(self: Selector, w: *std.Io.Writer) error{WriteFailed}!void {
    return if (self.option) |o|
        w.print("{f}Select boot option: {f} >\r\n{f}", .{ &self.timer, self.group.select(), o })
    else
        w.print("{f}Select boot group:\r\n{f}", .{ &self.timer, self.group });
}

const GroupWindow = Window(Config.Group);
const OptionWindow = Window(Config.Option);

/// Generate a rolling window style view of any type. The idea is that
/// you can only display X entries, and this allows you to never show
/// more than that at a time, with decent scrolling semantics.
fn Window(comptime T: type) type {
    return struct {
        const Win = @This();

        /// The index of the first element in the window.
        from: usize = 0,
        /// The number of elements in the window. This generally
        /// doesn't change during the lifetime of the object.
        size: usize = 0,
        /// The location of the user's cursor, displayed as a leading
        /// ">" in place of a " ".
        cursor: usize = 0,
        /// The backing element list.
        data: []const T,

        /// Create a Window of the generated type over the given data
        /// and a window size.
        pub fn init(data: []const T, size: usize) Win {
            if (data.len > size) return .{ .size = size, .data = data };
            return .{ .size = data.len, .data = data };
        }

        /// Helper function to calculate the end position of the
        /// window from the start and the size.
        inline fn to(self: Win) usize {
            return self.from + self.size;
        }

        /// By how much is the window "over" the limit? The idea is to
        /// lock the view to the bottom, such that scrolled all the
        /// way down, `size` elements remain visible. This is achieved
        /// by allowing a window to scroll "too much" and then
        /// scrolling it backwards by `over`.
        inline fn over(self: Win) usize {
            // max = len -| size; over = from -| max => from -| (len -| size)
            return self.from -| (self.data.len -| self.size);
        }

        /// Helper function to get the current window as a slice.
        pub fn window(self: Win) []const T {
            return self.data[self.from..][0..self.size];
        }

        /// Try to scroll the window down by `by` elements.
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

        /// Try to scroll the window up by `by` elements.
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

        /// Print the window, which essentially implies printing the
        /// native {f} format of each element, prefixed by either a
        /// " " (not selected) or a ">" (selected).
        pub fn format(self: Win, w: *std.Io.Writer) error{WriteFailed}!void {
            const s = self.window();
            for (s, 0..) |e, i| {
                const c: u21 = @as(u21, if (i == self.cursor) '>' else ' ');
                const l: u21 = @truncate(i + 'a');
                try w.print("{u}{u} {f}\r\n", .{ c, l, e });
            }
        }

        /// Helper function to get the current selection.
        pub fn select(self: Win) T {
            return self.window()[self.cursor];
        }

        /// Helper to know if an index is in range of the window. This
        /// is primarily used to handle jump labels (e.g. z) that may
        /// be out of the window's range.
        pub fn onPage(self: Win, idx: usize) bool {
            return idx < self.size;
        }
    };
}

/// A self-contained countdown-style timer. A typical UEFI timer will
/// simply fire once (or repeatedly) on a… timer. However, we want a
/// visible countdown. To achieve this, we have the timer fire every
/// 1s, keeping track of a counter.
const Timer = struct {
    /// The underlying timer. `null` implies it being disabled.
    event: ?uefi.Event = null,
    /// How many seconds until the timer triggers for real.
    counter: usize = 0,

    /// UEFI timers operate in 100ns intervals. Cache how many of
    /// those compose 1 second.
    const second: u64 = @intCast(@divTrunc(std.Io.Duration.fromSeconds(1).toNanoseconds(), 100));

    /// Returns true if the timer is currently active.
    pub inline fn running(self: Timer) bool {
        return self.event != null;
    }

    /// Try to cancel the timer running. This should normally never
    /// error out.
    pub fn cancel(self: *Timer) !void {
        if (self.event) |ev|
            try globals.boot_services.setTimer(ev, .cancel, 0);
    }

    /// Trigger a timer's tick. The timer is event-driven, meaning the
    /// caller is expected to wait on it and call this whenever it is
    /// triggered. If the countdown reaches 0, this will cancel the
    /// timer and return true, indicating that the overall timer has
    /// triggered.
    pub fn tick(self: *Timer) bool {
        self.counter -|= 1;
        if (self.counter == 0) {
            self.cancel() catch {};
            return true;
        }
        return false;
    }

    /// Initialize a timer that will trigger after `seconds` total seconds.
    pub fn create(seconds: usize) !Timer {
        const bs = globals.boot_services;

        const timer = try bs.createEvent(.{
            .timer = true,
        }, .{});
        errdefer bs.closeEvent(timer) catch {};

        try bs.setTimer(timer, .periodic, second);
        return .{ .event = timer, .counter = seconds };
    }

    /// Cancel the timer and attempt to free it as a whole. This will
    /// also set the internal event to null, short-circuiting most
    /// internal logic.
    /// For example, until the internal event is null, the timer is
    /// considered to be running, in spite of it potentially no longer
    /// ever triggering.
    pub fn destroy(self: *Timer) !void {
        try self.cancel();
        if (self.event) |ev|
            try globals.boot_services.closeEvent(ev);
        self.event = null;
    }

    /// Print the timer's status, which will either be an empty line,
    /// a notification that the timer could not be initialized, or the
    /// default option that will be selected and the number of seconds
    /// left on the timeout.
    pub fn format(self: *const Timer, w: *std.Io.Writer) error{WriteFailed}!void {
        const parent: *const Selector = @fieldParentPtr("timer", self);
        return if (parent.cfg.defaultOption()) |option|
            if (self.running())
                w.print("Booting default option in {:02}s: {f} > {f}\r\n", .{ self.counter, option.parent, option })
            else
                w.writeAll("\r\n")
        else
            w.writeAll("Timer is disabled because a default boot option oculd not be found.\r\n");
    }

    /// A valid empty timer that is not running.
    const empty: Timer = .{};
};
