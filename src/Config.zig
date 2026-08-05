const std  = @import("std");
const mem  = std.mem;
const uefi = std.os.uefi;
const uni  = std.unicode;

const globals = @import("globals.zig");
const text    = @import("text.zig");

const File    = @import("File.zig");

const Allocator     = mem.Allocator;
const DevicePath    = uefi.protocol.DevicePath;
const Error         = uefi.Error;
const ImageExitData = uefi.tables.BootServices.ImageExitData;
const LoadedImage   = uefi.protocol.LoadedImage;
const SplitIterator = mem.SplitIterator(u8, .scalar);

const Config = @This();

/// How long to wait with no input to boot the default boot option.
/// Set with !t[imeout] number.
timeout: u8 = 5,

/// How many options are allowed per display page.
/// Set with !p[agelen] number.
pagelen: u8 = 10,

default: []const u8 = "",

// DevicePath to use in constructing the chainload DevicePath.
device: *const DevicePath,

/// Underlying storage for the raw configuration files.
storage: [][]u8,

/// Configured boot groups.
items: []Group,

// assumes DevicePath, SFS volume
pub fn load(gpa: Allocator) Error!*Config {
    var out = gpa.create(Config) catch return Error.OutOfResources;
    errdefer out.destroy(gpa);

    out.timeout = 5; out.pagelen = 10; out.default = &.{};
    out.device = globals.devicepath;

    var root = try File.fromImage(gpa);
    defer root.destroy(gpa);

    // backing memory for essentially everything, goes into storage
    var buffers = std.ArrayList([]u8).empty;

    // read all the config files recursively
    // populating buffers (out.storage) and getting lines
    const lines = try loadFile(out, root, "tub.conf", gpa, &buffers);
    errdefer gpa.free(lines);
    out.storage = buffers.toOwnedSlice(gpa)
        catch return Error.OutOfResources;
    errdefer {
        for (out.storage) |buf| gpa.free(buf);
        gpa.free(out.storage);
    }

    out.items = gpa.alloc(Group, lines.len)
        catch return Error.OutOfResources;
    errdefer gpa.free(out.items);
    for (lines, 0..) |line, i| {
        // WARN: each out.item[*] leaks if a future one errors
        out.items[i].init(gpa, out, line, root)
            catch return Error.OutOfResources;
    }

    return out;
}

fn loadFile(
    self: *Config,
    root: File,
    name: []const u8,
    gpa: Allocator,
    bufs: *std.ArrayList([]u8),
) Error![]BootLine {
    var file = try root.open(gpa, name);
    defer file.destroy(gpa);

    const buf = file.slurp(gpa) catch return Error.OutOfResources;
    errdefer gpa.free(buf);

    var lines = std.ArrayList(BootLine).empty;
    errdefer lines.deinit(gpa);

    var it = mem.splitScalar(u8, buf, '\n');
    while (it.next()) |sline| switch (Line.create(@constCast(sline))) {
        .comment, .unrecognized => {},
        // NOTE: "" = disable filtering
        .default => |v| self.default = v,
        // NOTE: 0 = disable timer
        .timeout => |v| self.timeout = v,
        // NOTE: > 27 is not possible, 0 is nonsensical
        .pagelen => |v| self.pagelen = if (v == 0 or v > 27) 27 else v,
        .boot => |bl| lines.append(gpa, bl) catch return Error.OutOfResources,
        .include => |f| {
            // NOTE: there's no recursion protection
            if (loadFile(self, root, f, gpa, bufs)) |sublines|
                lines.appendSlice(gpa, sublines) catch return Error.OutOfResources
            else |_| {} // failing to load a file = skip it, all optional
        }
    };

    const out = lines.toOwnedSlice(gpa) catch return Error.OutOfResources;
    bufs.append(gpa, buf) // important that this is the last step
        catch return Error.OutOfResources;
    return out;
}

pub fn destroy(self: *Config, gpa: Allocator) void {
    for (self.storage) |file| gpa.free(file);
    gpa.free(self.storage);
    for (self.items) |*item| item.destroy(gpa);
    gpa.free(self.items);
    gpa.destroy(self);
}

pub fn defaultOption(self: Config) ?Option {
    for (self.items) |group| {
        for (group.items) |item| {
            // if default is set, the default item we pick must match
            if (self.default.len > 0) {
                if (text.glob(self.default, item.path)) return item;
            } else return item;
        }
    }
    return null;
}

/// A config file line that represents a boot group.
/// It's essentially a bunch of string views, so this is fine to stack-allocate.
const BootLine = struct {
    /// View of the backing physical line, without the terminating \n.
    buf: []const u8,

    /// Options for the sorter. Field 1.
    sorter:  text.Sorter,
    /// The glob of the files to include. Field 2.
    pattern: []const u8,
    /// The format string for the group's display. Field 3.
    group:   []const u8,
    /// The format string for the boot entries. Field 4.
    fmt:     []const u8,
    /// The command line to pass through when chainloading. Field 5.
    cmdline: []const u8,

    pub fn create(line: []u8) ?BootLine {
        var it = mem.splitScalar(u8, line, ':');
        const sort    = text.Sorter.init(it.first());
        const pattern = it.next() orelse return null;
        const group   = it.next() orelse return null;
        const fmt     = it.next() orelse return null;
        const cmdline = it.rest();

        // we signal that we may (and do) do this by having line be []u8
        // the alternative would be something like
        // line[sort.len+1..+pattern.len] but why do that when we have the slice?
        text.path.convert(@constCast(pattern));
        return .{
            .buf = line,

            .sorter  = sort,
            .pattern = pattern,
            .group   = group,
            .fmt     = fmt,
            .cmdline = cmdline,
        };
    }

    pub fn format(self: BootLine, w: *std.Io.Writer) !void {
        try w.writeAll(self.buf);
    }
};

const Line = union(enum) {
    boot: BootLine,

    // instead of having a sub-union these are inlined
    include: []const u8,
    timeout: u8,
    pagelen: u8,
    default: []const u8,

    comment, unrecognized,

    pub fn create(line: []u8) Line {
        if (line.len == 0)  return .comment;
        if (line[0] == '#') return .comment;

        if (line[0] != '!')
            return if (BootLine.create(line)) |bl|
                .{ .boot = bl } else .unrecognized;

        // !S[omething] payload
        if (line.len < 2) return .unrecognized;
        return switch (line[1]) {
            'd'  => createDefault(line[1..]),
            't'  => createTimeout(line[1..]),
            'i'  => createInclude(line[1..]),
            'p'  => createPagelen(line[1..]),
            else => .unrecognized,
        };
    }

    fn skipToPayload(line: []const u8) []const u8 {
        std.debug.assert(line.len > 0);
        var i: usize = 0;
        while (line[i] != ' ') {
            i += 1;
            if (line.len == i) return &.{};
        }
        while (line[i] == ' ') {
            i += 1;
            if (line.len == i) return &.{};
        }
        return line[i..];
    }

    fn createTimeout(line: []const u8) Line {
        std.debug.assert(line[0] == 't');
        const payload = skipToPayload(line);
        return if (std.fmt.parseUnsigned(u8, payload, 10)) |int|
            .{ .timeout = int } else |_| .unrecognized;
    }

    fn createInclude(line: []u8) Line {
        std.debug.assert(line[0] == 'i');
        const payload = skipToPayload(line);
        // we signal that we will do this by making line be []u8
        text.path.convert(@constCast(payload));
        return .{ .include = payload };
    }

    fn createPagelen(line: []const u8) Line {
        std.debug.assert(line[0] == 'p');
        const payload = skipToPayload(line);
        return if (std.fmt.parseUnsigned(u8, payload, 10)) |int|
            .{ .pagelen = int } else |_| .unrecognized;
    }

    fn createDefault(line: []const u8) Line {
        std.debug.assert(line[0] == 'd');
        const payload = skipToPayload(line);
        // TODO: this globs against the internal representation
        return .{ .default = payload };
    }
};

pub const Group = struct {
    parent: *const Config,
    line:   BootLine,
    items: []Option,

    pub fn init(
        out: *Group,
        gpa: Allocator,
        cfg: *Config,
        line: BootLine,
        root: File
    ) !void {
        out.parent = cfg;
        out.line   = line;

        // if there's no globbing pattern, we trust the hardcoded string
        if (!mem.containsAtLeastScalar(u8, line.pattern, '*', 1)) {
            out.items = try gpa.alloc(Option, 1);
            out.items[0] = .{.parent = out, .path = line.pattern};
            return;
        }

        // there is a globbing pattern, so we glob
        out.items = blk: {
            var items = std.ArrayList(Option).empty;
            errdefer items.deinit(gpa);

            const names = try root.find(line.pattern, gpa);
            defer gpa.free(names);

            for (names) |name|
                try items.append(gpa, .{
                    .parent = out,
                    .path   = name,
                });

            break :blk try items.toOwnedSlice(gpa);
        };

        out.line.sorter.sort(out.items);
    }

    pub fn destroy(self: *Group, gpa: Allocator) void {
        gpa.free(self.items);
    }

    pub fn format(self: Group, w: *std.Io.Writer) error{WriteFailed}!void {
        var escape = false;
        var view = uni.Utf8View.init(self.line.group)
            catch return error.WriteFailed;
        var it   = view.iterator();
        while (it.nextCodepoint()) |c| {
            if (escape) {
                switch (c) {
                    '%'  => try w.printUnicodeCodepoint('%'),
                    'n'  => try w.print("{d}", .{self.items.len}),
                    else => try w.print("%{u}", .{c}),
                }
                escape = false;
            } else if (c == '%') {
                escape = true;
            } else {
                try w.printUnicodeCodepoint(c);
            }
        }
        if (escape) try w.printUnicodeCodepoint('%');
    }
};

pub const Option = struct {
    parent: *const Group,
    path: []const u8,

    pub fn chainload(self: Option, gpa: Allocator) Error!ImageExitData {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var alloc = arena.allocator();

        const path = blk: {
            const len  = try text.calcUcs2Len(self.path);
            const out  = alloc.alloc(u16, len) catch return Error.OutOfResources;
            const real = try text.utf8ToUcs2(out, self.path);
            std.debug.assert(real == len);
            break :blk out;
        };

        const dp  = self.parent.parent.device.createFileDevicePath(alloc, path)
            catch return error.OutOfResources;
        const img = try globals.boot_services.loadImage(
            false, uefi.handle, .{ .device_path = dp }
        );

        const cmd = self.parent.line.cmdline;
        if (cmd.len > 0) {
            // uefi stub treats loadoptions as a []u16
            // so we have to cast to ucs2
            const buf = blk: {
                const len  = try text.calcUcs2Len(cmd);
                const out  = alloc.allocSentinel(u16, len, 0)
                    catch return error.OutOfResources;
                const real = try text.utf8ToUcs2(out, cmd);
                std.debug.assert(real == len);
                break :blk out;
            };
            const limg = try globals.boot_services.handleProtocol(LoadedImage, img)
                orelse return error.LoadError;
            // systemd stub expects UCS-2 formatting and size in bytes
            // 1+ is the sentinel
            const len = @sizeOf(u16) * (buf.len + 1);
            std.debug.assert(len <= std.math.maxInt(u32)); // cmdline too big
            limg.load_options_size = @truncate(len);
            limg.load_options = @ptrCast(buf.ptr);
        }

        return globals.boot_services.startImage(img);
    }

    pub fn format(self: Option, w: *std.Io.Writer) error{WriteFailed}!void {
        var escape = false;
        var view = uni.Utf8View.init(self.parent.line.fmt)
            catch return error.WriteFailed;
        var it   = view.iterator();
        while (it.nextCodepoint()) |c| {
            if (escape) {
                switch (c) {
                    '%' => try w.printUnicodeCodepoint('%'),
                    'p' => try w.writeAll(self.path),
                    'f' => try w.writeAll(text.path.filename(self.path)),
                    'b' => try w.writeAll(text.path.basename(self.path)),
                    'e' => try w.writeAll(text.path.extension(self.path)),
                    'd' => try w.writeAll(text.path.dirname(self.path)),
                    'c' => try w.writeAll(self.parent.line.cmdline),
                    'g' => try w.print("{f}", .{self.parent}),
                    else => try w.print("%{u}", .{c}),
                }
                escape = false;
            } else if (c == '%') {
                escape = true;
            } else {
                try w.printUnicodeCodepoint(c);
            }
        }
        if (escape) try w.printUnicodeCodepoint('%');
    }
};
