const std = @import("std");
const uefi = std.os.uefi;
const Error = uefi.Error;
const Status = uefi.Status;
const DevicePath = uefi.protocol.DevicePath;
const LoadedImage = uefi.protocol.LoadedImage;
const SimpleFileSystem = uefi.protocol.SimpleFileSystem;
const SimpleTextInput = uefi.protocol.SimpleTextInput;
const SimpleTextOutput = uefi.protocol.SimpleTextOutput;
const BootServices = uefi.tables.BootServices;
const SystemTable = uefi.tables.SystemTable;

const Config = @import("Config.zig");
const Console = @import("Console.zig");
const Editor = @import("Editor.zig");
const File = @import("File.zig");
const globals = @import("globals.zig");
const Selector = @import("Selector.zig");

/// Returns a std.os.uefi.Status.Error or null from any error. This is
/// needed because there is no safe way to coerce an error from one
/// set to another with a fallback. The idea is that `null` will
/// become Unexpected.
pub fn uefiError(e: anyerror) ?Status.Error {
    return switch (e) {
        Error.Aborted, Error.AccessDenied, Error.AlreadyStarted, Error.BadBufferSize, Error.BufferTooSmall, Error.CompromisedData, Error.ConnectionFin, Error.ConnectionRefused, Error.ConnectionReset, Error.CrcError, Error.DeviceError, Error.EndOfFile, Error.EndOfMedia, Error.HostUnreachable, Error.HttpError, Error.IcmpError, Error.IncompatibleVersion, Error.InvalidLanguage, Error.InvalidParameter, Error.IpAddressConflict, Error.LoadError, Error.MediaChanged, Error.NetworkUnreachable, Error.NoMapping, Error.NoMedia, Error.NoResponse, Error.NotFound, Error.NotReady, Error.NotStarted, Error.OutOfResources, Error.PortUnreachable, Error.ProtocolError, Error.ProtocolUnreachable, Error.SecurityViolation, Error.TftpError, Error.Timeout, Error.Unsupported, Error.VolumeCorrupted, Error.VolumeFull, Error.WriteProtected => |err| err,
        else => null, // Unexpected
    };
}

/// Physical UEFI entrypoint. This initializes the uefi handle and
/// system table, as well as the globals. I am planning to move the
/// this and the globals into the same file.
/// Then, this will run `main()`, which must have return type void
/// with an error union. If the returned error is in
/// std.os.uefi.Status.Error, then this will return the appropriate
/// error code, or it will panic due to an unexpected error. If main
/// returns without returning an error, this will return the success
/// status.
pub export fn EfiMain(handle: uefi.Handle, system_table: *SystemTable) callconv(.c) usize {
    uefi.handle = handle;
    uefi.system_table = system_table;
    globals.init();

    main() catch |err| return if (uefiError(err)) |e| @backingInt(Status.fromError(e)) else @panic("EfiMain: unexpected error");
    return @backingInt(uefi.Status.success);
}

/// Utility function to reboot the system.
inline fn reboot() noreturn {
    uefi.system_table.runtime_services.resetSystem(
        // TODO: "user requested reboot"; difficulty is align(2)
        .warm, .success, null);
}

fn main() !void {
    var console = Console.init();

    // TODO: switch on the errors
    // default config is now handled inside of Config.load
    // see Config.BootLine.default
    var cfg = Config.load(uefi.pool_allocator) catch return Error.NotFound;
    defer cfg.destroy(uefi.pool_allocator);

    var ui = Selector.init(cfg, &console);
    while (true) {
        const opt = try ui.step();
        console.clear();
        if (opt == null) continue;
        switch (opt.?) {
            .reboot => reboot(),
            .exit => return,
            .boot => |o| _ = try o.chainload(uefi.pool_allocator, null),
            .edit => |o| {
                var arena = std.heap.ArenaAllocator.init(uefi.pool_allocator);
                defer arena.deinit();
                const alloc = arena.allocator();

                const initial = o.parent.line.cmdline;
                const cmdline = try Editor.edit(initial, alloc);
                console.clear();
                _ = try o.chainload(alloc, cmdline);
            },
        }
    }
}
