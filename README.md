# Toast's UEFI Bootloader (tub)

tub is a UEFI-chainload only globbing bootloader.

This means:
- It is only capable of chainloading into other UEFI payloads, and only on the ESP it was booted off from.
- Its configuration (which is technically optional) can include globbing (`*`).

It is optimized specifically for the following cases:
- You want to minimize how much configuration you have to maintain per update: tub is built in such a way that no action is required on a kernel update.
  The config does not need regenerating.
- You are running multiple operating systems / tools: tub is built such that distributions do not need to fight over the global configuration.
- You are making a homegrown boot/install USB stick: tub is usable with 0 configuration (it discovers all .EFI files on the filesystem it booted from).

It is generally recommended to mount your ESP as /boot and have it be relatively large (16+GB).
See `tub(5)` and `tub(7)` for the configuration file format and general introduction on how to use tub respectively.

## Rationale

Multi-boot systems (of any kind) create a social ownership problem.
Under typical linux bootloaders, the configuration is strict (i.e. each path has to be individually configured, and discovery happens at generation time), while there are no includes.
This means that every kernel update, the configuration has to be updated, creating an incentive for an installed OS to "own" the bootloader configuration.

When multiple operating systems are installed, each one has this incentive, but they are highly likely to share a single ESP.
In other words, they will fight over control of the same bootloader's configuration.
Tub is an attempt to resolve this, as well as provide for some other use-cases (bootable USBs, manual bootloader management, non-linux operating systems).

---

I have had an observation that most bootloader configurations follow an extremely predictable pattern: this file, with that cmdline, the cmdline doesn't change across kernel versions.
Generally, one wants the latest kernel to be automatically selected, but with the ability to pick an older one in case there is a regression.
Each tub configuration line (internally BootLine) represents a set of kernels (for example `/EFI/Linux/void-*.efi`) that all share the same cmdline. You can order them alphabetically or reversed (which would make the newest the default).
To override, you'd use the `!default` directive (for example `!default *\void-7.0*`), which is treated like a special case.

A distribution doesn't need to control the bootloader's configuration because the `!include` directive exists.
The recommended approach is to write to the ESP's `/tub/INSTALL_ID.conf` and create `/tub.conf` with `!include /tub/INSTALL_ID.conf` if it doesn't already exist.
Since globbing is in place, there is nothing to do on a kernel update besides place it in the location where it will be discovered.

Since the order of configuration lines matters for default selection, the user can swap their default boot by editing tub.conf and changing the order of the `!include` directives.
Furthermore, changing the cmdline now only entails changing the one applicable config line.
The only disadvantage to this approach is the "safe option set" (or otherwise single user mode) configurations needing a second line, which is deemed acceptable.
The user can also use a line-editor to change the cmdline, meaning adding an "S" or "init=/bin/bash" is not very difficult.

---

There are operating systems out there that are not Linux, and each one has its own boot protocol.
On the other hand, the UEFI chainloading protocol (cmdline is UCS-2 formatted ExtraData) is fairly universal.
Every bootloader having to implement every boot protocol for every OS possible just means that the OS will always depend on externalities, and every bootloader has a ton of work to do for little reason.
I believe instead that every OS should implement a (however minimal) EFI-stub, so the work is distributed in an agnostic way.
tub is capable of booting CONFIG_EFI kernels directly (with no initramfs), but the recommendation is to use UKIs, or an equivalent for other operating systems.
In this respect, tub can be thought of as a fancy picker dialogue with semi-manual groupings, that doesn't depend on things like the UEFI variables being writable.

---

If you're making a bootable USB or rescue disc or similar, the traditional approach has been to follow a particular incantation that makes it bootable on both MBR and UEFI.
This meant generating an .iso, with a squashfs somewhere, etc. It was always a bit of a pain.
Nowadays, even many aarch64 platforms have UEFI.
With tub, you format your USB as fat32 (most people are capable of doing this), drop it into `/EFI/BOOT/BOOT????.EFI`, and drop your UKI anywhere on the disk.
Your UKI either contains the entire rootfs as an initramfs (running from RAM, which for small rescue systems is perfectly reasonable nowadays), or has just enough to load a .squashfs that can be on the same fat32 partition (doesn't need much: just usb drivers and a fat32 driver).
No further configuration is required, though if you're making a home grown rescue disc, you may want multiple rescue UKIs as well as some UEFI tools (like the UEFI shell), in which case you can create a tub.conf to separate them.
