//! Configuration reader for the `tub(5)` format.
const std = @import("std");
const mem = std.mem;
const uefi = std.os.uefi;
const uni = std.unicode;
const Allocator = mem.Allocator;
const DevicePath = uefi.protocol.DevicePath;
const Error = uefi.Error;
const ImageExitData = uefi.tables.BootServices.ImageExitData;
const LoadedImage = uefi.protocol.LoadedImage;

const File = @import("File.zig");
const globals = @import("globals.zig");
const text = @import("text.zig");

const Config = @This();

const SplitIterator = mem.SplitIterator(u8, .scalar);

/// How long to wait with no input to boot the default boot option.
/// Set with !t[imeout] number.
timeout: u8 = 5,

/// How many options are allowed per display page.
/// Set with !p[agelen] number.
pagelen: u8 = 10,

/// A glob pattern to match against the internal path representation of Options
/// when picking a default boot option. Empty means no filtering takes place.
/// Set with !d[efault] pattern.
default: []const u8 = "",

/// DevicePath to use in constructing the chainload
/// DevicePath. Overriding this makes it possible to boot files in
/// other partitions, but then you also have to override `load`.
device: *const DevicePath,

/// Underlying storage for the raw configuration files.
storage: [][]u8,

/// Configured boot groups.
items: []Group,

/// Recursively reads the system's configuration from the corresponding tub.conf.
pub fn load(gpa: Allocator) Error!*Config {
    var out = gpa.create(Config) catch return Error.OutOfResources;
    errdefer out.destroy(gpa);

    out.timeout = 5;
    out.pagelen = 10;
    out.default = &.{};
    out.device = globals.devicepath;

    var root = try File.fromImage(gpa);
    defer root.destroy(gpa);

    // backing memory for essentially everything, goes into storage
    var buffers = std.ArrayList([]u8).empty;

    // read all the config files recursively
    // populating buffers (out.storage) and getting lines
    const lines = loadFile(out, root, "tub.conf", gpa, &buffers) catch blk: {
        // HERE: modify out to change things only accessible via directives, if any
        break :blk gpa.dupe(BootLine, &BootLine.default) catch return Error.OutOfResources;
    };
    errdefer gpa.free(lines);
    out.storage = buffers.toOwnedSlice(gpa) catch return Error.OutOfResources;
    errdefer {
        for (out.storage) |buf| gpa.free(buf);
        gpa.free(out.storage);
    }

    out.items = gpa.alloc(Group, lines.len) catch return Error.OutOfResources;
    errdefer gpa.free(out.items);
    for (lines, 0..) |line, i| {
        // WARN: each out.item[*] leaks if a future one errors
        out.items[i].init(gpa, out, line, root) catch return Error.OutOfResources;
    }

    return out;
}

/// Worker function that actually parses each individual file.
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
        },
    };

    const out = lines.toOwnedSlice(gpa) catch return Error.OutOfResources;
    bufs.append(gpa, buf) // important that this is the last step
    catch return Error.OutOfResources;
    return out;
}

/// Frees backing storage (file buffers) and items.
pub fn destroy(self: *Config, gpa: Allocator) void {
    for (self.storage) |file| gpa.free(file);
    gpa.free(self.storage);
    for (self.items) |*item| item.destroy(gpa);
    gpa.free(self.items);
    gpa.destroy(self);
}

/// Finds the default boot option. Note that no caching is done, meaning that if
/// you have a globbing pattern set, it will repeatedly be called in a linear
/// search.
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
    sorter: text.Sorter,
    /// The glob of the files to include. Field 2.
    pattern: []const u8,
    /// The format string for the group's display. Field 3.
    group: []const u8,
    /// The format string for the boot entries. Field 4.
    fmt: []const u8,
    /// The command line to pass through when chainloading. Field 5.
    cmdline: []const u8,

    /// Parses a line (should not contain \n). Returns null on errors to skip.
    pub fn create(line: []u8) ?BootLine {
        var it = mem.splitScalar(u8, line, ':');
        const sort = text.Sorter.init(it.first());
        const pattern = it.next() orelse return null;
        const group = it.next() orelse return null;
        const fmt = it.next() orelse return null;
        const cmdline = it.rest();

        // we signal that we may (and do) do this by having line be []u8
        // the alternative would be something like
        // line[sort.len+1..+pattern.len] but why do that when we have the slice?
        if (mem.containsAtLeastScalar(u8, pattern, '/', 1))
            text.path.convert(@constCast(pattern));
        return .{
            .buf = line,

            .sorter = sort,
            .pattern = pattern,
            .group = group,
            .fmt = fmt,
            .cmdline = cmdline,
        };
    }

    /// See std.Io.Writer.print.
    pub fn format(self: BootLine, w: *std.Io.Writer) !void {
        try w.writeAll(self.buf);
    }

    /// The default configuration lines. For directives, the defaults
    /// are the default.
    const default = [_]BootLine{
        BootLine.create(@constCast("pr:**.efi:Discovered EFI files (%n):%p:")).?,
    };
};

/// Represents a line in the configuration file.
/// A line may generally represent a boot group (BootLine),
/// a directive (such as an !include), or may be empty/a comment.
const Line = union(enum) {
    /// A materialized boot group.
    boot: BootLine,

    // instead of having a sub-union these are inlined
    /// A directive to include the file in the payload.
    /// Globbing is unsupported.
    include: []const u8,
    /// A directive to set the timeout for the default boot timer.
    timeout: u8,
    /// A directive to set the maximum number of options that may be shown per
    /// page.
    pagelen: u8,
    /// A directive to set a globbing pattern to consider when selecting a
    /// default boot option.
    default: []const u8,

    /// A comment, meaning a line starting with #
    comment,

    /// An unrecognized line that will be ignored.
    unrecognized,

    /// Parses a physical configuration line, calling out to the appropriate
    /// parser for each specific entry kind. You can tell the kind of line from
    /// the first character (! is a directive and # is a comment), and the type
    /// of directive from the 2nd character.
    pub fn create(line: []u8) Line {
        if (line.len == 0) return .comment;
        if (line[0] == '#') return .comment;

        if (line[0] != '!')
            return if (BootLine.create(line)) |bl|
                .{ .boot = bl }
            else
                .unrecognized;

        // !S[omething] payload
        if (line.len < 2) return .unrecognized;
        return switch (line[1]) {
            'd' => createDefault(line[1..]),
            'i' => createInclude(line[1..]),
            'p' => createPagelen(line[1..]),
            't' => createTimeout(line[1..]),
            else => .unrecognized,
        };
    }

    /// Convenience function to get the payload of a directive.
    /// The payload is defined as all the text after the first group of spaces
    /// in the config line. This means a directive can never start with a space.
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

    /// Parses a timeout, which is defined as an integer.
    /// The maximum value is 255, which may be raised later.
    fn createTimeout(line: []const u8) Line {
        std.debug.assert(line[0] == 't');
        const payload = skipToPayload(line);
        return if (std.fmt.parseUnsigned(u8, payload, 10)) |int|
            .{ .timeout = int }
        else |_|
            .unrecognized;
    }

    /// Parses an include directive, which is defined as a path to include.
    fn createInclude(line: []u8) Line {
        std.debug.assert(line[0] == 'i');
        const payload = skipToPayload(line);
        // we signal that we will do this by making line be []u8
        text.path.convert(@constCast(payload));
        return .{ .include = payload };
    }

    /// Parses a pagelen directive, which is defined as an integer.
    /// The maximum value is 255, but in practice it's actually 27, since jump
    /// labels >z are nonsensical.
    fn createPagelen(line: []const u8) Line {
        std.debug.assert(line[0] == 'p');
        const payload = skipToPayload(line);
        return if (std.fmt.parseUnsigned(u8, payload, 10)) |int|
            .{ .pagelen = int }
        else |_|
            .unrecognized;
    }

    /// Parses a default directive, which is defined as a pattern.
    /// It will glob against the full internal representation of the filepath,
    /// so it is highly recommended to start it with a "*\".
    /// A good example is `*\mydistro-7.1.1*` or `*\Shell.efi`.
    fn createDefault(line: []const u8) Line {
        std.debug.assert(line[0] == 'd');
        const payload = skipToPayload(line);
        // TODO: this globs against the internal representation
        return .{ .default = payload };
    }
};

/// A boot group representing all the options under a specific BootLine.
/// Groups are created this way because all options in a BootLine share
/// their cmdline and formatting options.
pub const Group = struct {
    /// Pointer to the config struct containing this.
    /// It's not possible to use @fieldParentPtr since Group resides in a slice.
    /// It's needed to have access to global Config options like the timeout.
    parent: *const Config,
    /// The bootline that defined this Group.
    /// It's needed to have access to the cmdline, format strings, etc.
    /// It's kept in-line since it just contains a few pointers.
    line: BootLine,
    /// The concrete boot options inside the group.
    /// These are generated by actually searching through the filesystem,
    /// unless the BootLine pattern doesn't contain a glob character, in which
    /// case we trust the user and do not verify the presence of the target.
    items: []Option,

    /// Creates the Group by filling it with options, whether by copying the
    /// single non-globbing pattern as-is, or by searching the filesystem for
    /// matches recursively.
    pub fn init(out: *Group, gpa: Allocator, cfg: *Config, line: BootLine, root: File) !void {
        out.parent = cfg;
        out.line = line;

        // if there's no globbing pattern, we trust the hardcoded string
        if (!mem.containsAtLeastScalar(u8, line.pattern, '*', 1)) {
            out.items = try gpa.alloc(Option, 1);
            out.items[0] = .{ .parent = out, .path = line.pattern };
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
                    .path = name,
                });

            break :blk try items.toOwnedSlice(gpa);
        };

        out.line.sorter.sortField(Option, out.items, "path");
    }

    /// Releases the backing slice for the storage.
    pub fn destroy(self: *Group, gpa: Allocator) void {
        for (self.items) |item| {
            gpa.free(item.path);
        }
        gpa.free(self.items);
    }

    /// See std.Io.Writer.print for details.
    /// The group format string supports the following escapes:
    /// * %%: prints a literal "%"
    /// * %c: prints the configured cmdline for this option group
    /// * %n: prints the number of options inside the group
    pub fn format(self: Group, w: *std.Io.Writer) error{WriteFailed}!void {
        var escape = false;
        var view = uni.Utf8View.init(self.line.group) catch return error.WriteFailed;
        var it = view.iterator();
        while (it.nextCodepoint()) |c| {
            if (escape) {
                switch (c) {
                    '%' => try w.printUnicodeCodepoint('%'),
                    'c' => try w.print("{s}", .{self.line.cmdline}),
                    'n' => try w.print("{d}", .{self.items.len}),
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

/// Represents a concrete boot option.
pub const Option = struct {
    /// The parent group this option belongs to.
    parent: *const Group,
    /// The path this boot option is at. This is an internal
    /// representation that can be used directly to create a file
    /// device path for LoadImage. Note that the creator of the Option
    /// owns this memory.
    path: []const u8,

    /// Chainload into this boot option. An allocator is required to create the
    /// deviceFilePath. It's safe to pass a gpa here, an arena is created
    /// internally. If cmdline is given, it will override the configured one.
    /// This is primarily useful for changing the configured cmdline at runtime.
    pub fn chainload(self: Option, gpa: Allocator, cmdline: ?[]const u16) Error!ImageExitData {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var alloc = arena.allocator();

        const path = blk: {
            const len = try text.calcUcs2Len(self.path);
            const out = alloc.alloc(u16, len) catch return Error.OutOfResources;
            const real = try text.utf8ToUcs2(out, self.path);
            std.debug.assert(real == len);
            break :blk out;
        };

        const dp = self.parent.parent.device.createFileDevicePath(alloc, path) catch return error.OutOfResources;
        const img = try globals.boot_services.loadImage(false, uefi.handle, .{ .device_path = dp });

        const cmd: []const u16 = if (cmdline) |cmd| cmd else blk: {
            const cmd = self.parent.line.cmdline;
            if (cmd.len == 0) break :blk ([0]u16{})[0..0];

            const len = try text.calcUcs2Len(cmd);
            const out = alloc.alloc(u16, len) catch return error.OutOfResources;
            const real = try text.utf8ToUcs2(out, cmd);
            std.debug.assert(real == len);
            break :blk out;
        };

        if (cmd.len > 0) {
            const final = alloc.dupeSentinel(u16, cmd, 0) catch return error.OutOfResources;

            const limg = try globals.boot_services.handleProtocol(LoadedImage, img) orelse return error.LoadError;
            const len = @sizeOf(u16) * (final.len + 1);
            std.debug.assert(len <= std.math.maxInt(u32));

            limg.load_options_size = @truncate(len);
            limg.load_options = @ptrCast(final.ptr);
        }

        return globals.boot_services.startImage(img);
    }

    /// See std.Io.Writer.print.
    /// The option format string supports the following escapes:
    /// * %%: prints a literal "%"
    /// * %p: prints the path to the option file
    /// * %f: prints the filename component of the path
    ///   defined as everything after the last '\',
    ///   or the whole path if there isn't one
    /// * %b: prints the basename of the filename,
    ///   defined as everything up to the last '.',
    ///   or the whole filename if there isn't one
    /// * %e: prints the extension of the filename,
    ///   defined as everything after the last '.',
    ///   or the empty string if there isn't one
    /// * %d: prints the directory component of the path,
    ///   defined as everything up to the last '\',
    ///   or the empty string if there isn't one
    /// * %c: prints the configured/default cmdline for this option
    /// * %g: prints the formatted representation of this option's group
    pub fn format(self: Option, w: *std.Io.Writer) error{WriteFailed}!void {
        var escape = false;
        var view = uni.Utf8View.init(self.parent.line.fmt) catch return error.WriteFailed;
        var it = view.iterator();
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
