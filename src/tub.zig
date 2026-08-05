const std  = @import("std");
const uefi = std.os.uefi;

const Console  = @import("Console.zig");
const Config   = @import("Config.zig");
const Editor   = @import("Editor.zig");
const File     = @import("File.zig");
const Selector = @import("Selector.zig");
const globals  = @import("globals.zig");

const Error  = uefi.Error;
const Status = uefi.Status;
const DevicePath       = uefi.protocol.DevicePath;
const LoadedImage      = uefi.protocol.LoadedImage;
const SimpleFileSystem = uefi.protocol.SimpleFileSystem;
const SimpleTextInput  = uefi.protocol.SimpleTextInput;
const SimpleTextOutput = uefi.protocol.SimpleTextOutput;
const BootServices     = uefi.tables.BootServices;
const SystemTable      = uefi.tables.SystemTable;

pub fn uefiError(e: anyerror) ?Status.Error {
    return switch (e) {
        Error.Aborted,
        Error.AccessDenied,
        Error.AlreadyStarted,
        Error.BadBufferSize,
        Error.BufferTooSmall,
        Error.CompromisedData,
        Error.ConnectionFin,
        Error.ConnectionRefused,
        Error.ConnectionReset,
        Error.CrcError,
        Error.DeviceError,
        Error.EndOfFile,
        Error.EndOfMedia,
        Error.HostUnreachable,
        Error.HttpError,
        Error.IcmpError,
        Error.IncompatibleVersion,
        Error.InvalidLanguage,
        Error.InvalidParameter,
        Error.IpAddressConflict,
        Error.LoadError,
        Error.MediaChanged,
        Error.NetworkUnreachable,
        Error.NoMapping,
        Error.NoMedia,
        Error.NoResponse,
        Error.NotFound,
        Error.NotReady,
        Error.NotStarted,
        Error.OutOfResources,
        Error.PortUnreachable,
        Error.ProtocolError,
        Error.ProtocolUnreachable,
        Error.SecurityViolation,
        Error.TftpError,
        Error.Timeout,
        Error.Unsupported,
        Error.VolumeCorrupted,
        Error.VolumeFull,
        Error.WriteProtected => |err| err,
        else => null, // Unexpected
    };
}

// this is mostly as is from start.zig:EfiMain
// the idea is I can expand on this later to
// (for example) initialize a minimal init or something
pub export fn EfiMain(
    handle: uefi.Handle,
    system_table: *SystemTable
) callconv(.c) usize {
    uefi.handle = handle;
    uefi.system_table = system_table;
    globals.init();

    main() catch |err| return
        if (uefiError(err)) |e| @intFromEnum(Status.fromError(e))
        else @panic("EfiMain: unexpected error");
    return @intFromEnum(uefi.Status.success);
}

inline fn reboot() noreturn {
    uefi.system_table.runtime_services.resetSystem(
        // TODO: "user requested reboot"; difficulty is align(2)
        .warm, .success, null);
}

fn main() !void {
    var console = Console.init();

    var cfg = Config.load(uefi.pool_allocator)
        catch return Error.NotFound; // TODO: default config
    defer cfg.destroy(uefi.pool_allocator);

    var ui = Selector.init(cfg, &console);
    while (true) {
        const opt = try ui.step();
        if (opt == null) continue;
        switch (opt.?) {
            .reboot => reboot(),
            .exit   => return,
            .boot   => |o| _ = try o.chainload(uefi.pool_allocator, null),
            .edit   => |o| {
                var arena = std.heap.ArenaAllocator.init(uefi.pool_allocator);
                defer arena.deinit();
                const alloc = arena.allocator();

                const initial = o.parent.line.cmdline;
                _ = try o.chainload(alloc, try Editor.edit(initial, alloc));
            },
        }
    }
}
