const std  = @import("std");
const uefi = std.os.uefi;

const DevicePath       = uefi.protocol.DevicePath;
const LoadedImage      = uefi.protocol.LoadedImage;
const SimpleFileSystem = uefi.protocol.SimpleFileSystem;
const SimpleTextInput  = uefi.protocol.SimpleTextInput;
const SimpleTextOutput = uefi.protocol.SimpleTextOutput;
const BootServices     = uefi.tables.BootServices;

pub var boot_services: *BootServices = undefined;
pub var stdin:  *SimpleTextInput     = undefined;
pub var stdout: *SimpleTextOutput    = undefined;
pub var image: *LoadedImage          = undefined;
pub var devicepath: *DevicePath      = undefined;
pub var sfs: *SimpleFileSystem       = undefined;

pub fn init() void {
    const system_table = uefi.system_table;
    boot_services = system_table.boot_services
        orelse @panic("EfiMain: no boot services");
    stdin = system_table.con_in
        orelse @panic("EfiMain: no stdin");
    stdout = system_table.con_out
        orelse @panic("EfiMain: no stdout");
    image = boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)
        catch  @panic("EfiMain: no LoadedImage")
        orelse @panic("EfiMain: no LoadedImage");
    const dh = image.device_handle orelse @panic("EfiMain: no Device Handle");
    devicepath = boot_services.handleProtocol(DevicePath, dh)
        catch  @panic("EfiMain: no DevicePath")
        orelse @panic("EfiMain: no DevicePath");
    sfs = boot_services.handleProtocol(SimpleFileSystem, dh)
        catch  @panic("EfiMain: no SimpleFileSystem")
        orelse @panic("EfiMain: no SimpleFileSystem");
}
